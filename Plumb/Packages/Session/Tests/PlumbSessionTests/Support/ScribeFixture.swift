import Foundation
import PlumbContracts
@testable import PlumbSession

/// A 100 second session with round, known numbers, for testing the sentence checker.
///
/// Four blocks of 40 compressions, two a second, starting at 3 s, 31.5 s, 55 s and 79.5 s.
/// That leaves three pauses of 9 s, 4 s and 5 s. Every fifth compression was measured while
/// depth was not trusted (and reads a wild 70 mm, to show it is ignored). The trusted ones
/// cycle through 47, 52, 54 and 58 mm.
///
/// By hand, that gives: 160 compressions, 120 per minute, typical depth 53 mm, range 47 to 58 mm
/// (shown as "4.5 to 6 cm"), 80% trusted, 75% of trusted reaching 50 mm, 3 pauses, longest 9 s,
/// first compression at 3 s, hands on for 1 - 18/97 = 81% of the time.
struct ScribeFixture {
    static let endT: TimeInterval = 100
    static let zone = TimeZone.gmt

    let log: [LogEntry]
    let stats: HandoffStats
    let startID: Int
    let compressionIDs: [Int]
    let pauseIDs: [Int]

    init() {
        var recorder = SessionRecorder(startedWallClock: fixtureStart)
        let trustedDepths: [Double] = [47, 52, 54, 58]
        var count = 0
        var lastBottom: TimeInterval?
        for blockStart in [3, 31.5, 55, 79.5] {
            for step in 0..<40 {
                let t = blockStart + 0.5 * Double(step)
                if step == 0, let lastBottom {
                    recorder.record([.pauseEnded(at: t, duration: t - lastBottom)])
                }
                let isTrusted = count % 5 != 4
                recorder.record([.compression(stroke(count + 1, at: t,
                                                     depth: isTrusted ? trustedDepths[count % 5] : 70,
                                                     interval: step == 0 ? nil : 0.5,
                                                     lock: isTrusted ? .locked : .estimating))])
                count += 1
                lastBottom = t
            }
        }
        recorder.end(at: Self.endT, openPauseSince: nil)

        log = recorder.log.entries
        stats = HandoffCalculator.stats(log: log, endT: Self.endT)
        startID = 1
        compressionIDs = log.filter { if case .compression = $0.body { true } else { false } }.map(\.id)
        pauseIDs = log.filter { if case .pause = $0.body { true } else { false } }.map(\.id)
    }

    /// The id of a compression that was measured while depth was not trusted.
    var untrustedCompressionID: Int {
        compressionIDs[4]
    }

    func verify(_ sentences: [ScribeSentence], maxSentences: Int = 3) -> [ScribeVerdict] {
        ScribeVerifier.verify(sentences, log: log, stats: stats, maxSentences: maxSentences, timeZone: Self.zone)
    }

    /// Checks one sentence on its own. By default it cites the first compression.
    func verdict(_ text: String, cites: [Int]? = nil) -> ScribeVerdict {
        verify([ScribeSentence(text: text, cites: cites ?? [compressionIDs[0]])])[0]
    }
}
