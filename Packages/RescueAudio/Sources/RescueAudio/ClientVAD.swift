import Foundation

/// Energy-based voice activity detection for the mic uplink. Runs off the render thread.
///
/// Keeps metronome ticks off the uplink: audio must stay above the noise floor for about 120 ms to
/// open it, and a click is far shorter. The gap between the two clicks of a beat resets that count.
public struct ClientVAD: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var sampleRate = 16_000
        public var minimumSpeechMilliseconds = 120
        public var hangoverMilliseconds = 300
        public var preRollMilliseconds = 300
        public var chunkMilliseconds = 20
        public var minimumLevelDB: Float = -50
        public var openMarginDB: Float = 12
        public var holdMarginDB: Float = 8

        public init() {}
    }

    public enum Output: Sendable, Equatable {
        case speechStarted
        case audio([Int16])
        case speechEnded
    }

    private static let frameMilliseconds = 10
    /// A dip this short doesn't restart the count, so a syllable's brief dip can't block opening.
    private static let toleratedGapFrames = 1
    private static let floorRiseDBPerFrame: Float = 0.02
    private static let floorFallPerFrame: Float = 0.1

    private let configuration: Configuration
    private let frameLength: Int
    private let framesToOpen: Int
    private let framesToClose: Int
    private let preRollLength: Int
    private let chunkLength: Int

    private var unframed: [Int16] = []
    private var preRoll: [Int16] = []
    private var pendingChunk: [Int16] = []
    private var activeFrames = 0
    private var gapFrames = 0
    private var silentFrames = 0
    private var noiseFloorDB: Float

    public private(set) var isOpen = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        frameLength = configuration.sampleRate * Self.frameMilliseconds / 1000
        framesToOpen = configuration.minimumSpeechMilliseconds / Self.frameMilliseconds
        framesToClose = configuration.hangoverMilliseconds / Self.frameMilliseconds
        preRollLength = configuration.sampleRate * configuration.preRollMilliseconds / 1000
        chunkLength = configuration.sampleRate * configuration.chunkMilliseconds / 1000
        noiseFloorDB = configuration.minimumLevelDB - configuration.openMarginDB
    }

    public mutating func process(_ samples: [Int16]) -> [Output] {
        var output: [Output] = []
        unframed.append(contentsOf: samples)
        var start = 0
        while unframed.count - start >= frameLength {
            analyze(unframed[start..<(start + frameLength)], into: &output)
            start += frameLength
        }
        unframed.removeFirst(start)
        return output
    }

    /// Forgets all buffered audio, including the pre-roll. Use when the uplink must not carry what
    /// was just heard, such as while a dispatcher may be audible.
    public mutating func reset() -> [Output] {
        let wasOpen = isOpen
        unframed.removeAll(keepingCapacity: true)
        close()
        return wasOpen ? [.speechEnded] : []
    }

    private mutating func close() {
        isOpen = false
        preRoll.removeAll(keepingCapacity: true)
        // A partial chunk here is only hangover silence, and a shorter chunk would break the 20 ms minimum.
        pendingChunk.removeAll(keepingCapacity: true)
        activeFrames = 0
        gapFrames = 0
        silentFrames = 0
    }

    private mutating func analyze(_ frame: ArraySlice<Int16>, into output: inout [Output]) {
        let level = Self.levelDB(frame)
        let margin = isOpen ? configuration.holdMarginDB : configuration.openMarginDB
        let isActive = level >= max(configuration.minimumLevelDB, noiseFloorDB + margin)
        updateNoiseFloor(level)

        if isOpen {
            appendToUplink(frame, into: &output)
            silentFrames = isActive ? 0 : silentFrames + 1
            if silentFrames >= framesToClose {
                close()
                output.append(.speechEnded)
            }
            return
        }

        preRoll.append(contentsOf: frame)
        if preRoll.count > preRollLength { preRoll.removeFirst(preRoll.count - preRollLength) }
        if isActive {
            activeFrames += 1
            gapFrames = 0
        } else {
            gapFrames += 1
            if gapFrames > Self.toleratedGapFrames { activeFrames = 0 }
        }
        if activeFrames >= framesToOpen {
            isOpen = true
            activeFrames = 0
            gapFrames = 0
            silentFrames = 0
            output.append(.speechStarted)
            appendToUplink(preRoll[...], into: &output)
            preRoll.removeAll(keepingCapacity: true)
        }
    }

    private mutating func appendToUplink(_ samples: ArraySlice<Int16>, into output: inout [Output]) {
        pendingChunk.append(contentsOf: samples)
        var start = 0
        while pendingChunk.count - start >= chunkLength {
            output.append(.audio(Array(pendingChunk[start..<(start + chunkLength)])))
            start += chunkLength
        }
        pendingChunk.removeFirst(start)
    }

    // The floor drops quickly and climbs slowly, so speech can't teach it much, while a fan that
    // starts up is learned within seconds and can't hold the uplink open.
    private mutating func updateNoiseFloor(_ level: Float) {
        if level < noiseFloorDB {
            noiseFloorDB += (level - noiseFloorDB) * Self.floorFallPerFrame
        } else {
            noiseFloorDB += Self.floorRiseDBPerFrame
        }
    }

    private static func levelDB(_ frame: ArraySlice<Int16>) -> Float {
        var sum: Float = 0
        for sample in frame {
            let value = Float(sample) / 32768
            sum += value * value
        }
        return 10 * log10(sum / Float(frame.count) + 1e-12)
    }
}
