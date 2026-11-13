import AVFoundation

/// The audio engine and its wiring: the beat and two speech players, all into one mixer.
///
/// Cues and model speech get a player each so that a cue can cut the model off without
/// touching its own queue.
final class AudioGraph {
    /// Where the mixed sound goes.
    enum Output: Sendable {
        /// The device's speaker, in real time.
        case speaker
        /// Nowhere: the caller pulls the sound out by hand, at most `maximumFrames` at a time.
        /// This is how the tests hear the real graph without a speaker.
        case offline(maximumFrames: AVAudioFrameCount)
    }

    let engine = AVAudioEngine()
    let cuePlayer = AVAudioPlayerNode()
    let modelPlayer = AVAudioPlayerNode()
    private let beatSource: AVAudioSourceNode

    init(config: BeatEngine.Config, renderer: BeatRenderer, output: Output) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 1) else {
            throw BeatEngineError.unusableSampleRate
        }
        beatSource = AVAudioSourceNode(format: format) { _, timestamp, frameCount, list in
            renderer.render(frameCount: Int(frameCount), timestamp: timestamp, into: list)
            return noErr
        }

        if case .offline(let maximumFrames) = output {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrames)
        }
        engine.attach(beatSource)
        engine.attach(cuePlayer)
        engine.attach(modelPlayer)
        // One format for everything, wired once. Rewiring a player for another sample rate was
        // measured to change its level by 3 dB, so speech is brought to this format before it is queued.
        engine.connect(beatSource, to: engine.mainMixerNode, format: format)
        engine.connect(cuePlayer, to: engine.mainMixerNode, format: format)
        engine.connect(modelPlayer, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        modelPlayer.volume = Float(config.modelGain)
        engine.prepare()
    }

    /// Pulls the next `frameCount` samples out of a graph made for offline output.
    func renderOffline(frameCount: Int) throws -> [Float] {
        guard engine.isInManualRenderingMode,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw OfflinePullError.notOffline }
        var samples: [Float] = []
        samples.reserveCapacity(frameCount)
        while samples.count < frameCount {
            let wanted = min(AVAudioFrameCount(frameCount - samples.count), buffer.frameCapacity)
            let status = try engine.renderOffline(wanted, to: buffer)
            guard status == .success, buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
                throw OfflinePullError.nothingRendered
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }
}

/// Why sound could not be pulled out of the graph by hand.
enum OfflinePullError: Error {
    /// The graph was made for the speaker.
    case notOffline
    /// The engine did not hand back the samples asked for.
    case nothingRendered
}
