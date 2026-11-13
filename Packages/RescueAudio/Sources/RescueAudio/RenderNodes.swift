import AVFAudio

// Running these closures touches no reference count, allocates nothing, and takes no lock, because
// all they capture is a `RenderCore` by value.
extension RenderCore {
    /// Connects the metronome and voice sources to the main mixer, which resamples them both.
    func attachOutputs(to engine: AVAudioEngine) -> Bool {
        guard
            let clickFormat = AVAudioFormat(standardFormatWithSampleRate: Double(Self.clickSampleRate), channels: 1),
            let voiceFormat = makeVoiceFormat()
        else { return false }

        let mixer = engine.mainMixerNode
        let click = makeMetronomeNode(format: clickFormat)
        let voice = makeVoiceNode(format: voiceFormat)
        engine.attach(click)
        engine.attach(voice)
        engine.connect(click, to: mixer, format: clickFormat)
        engine.connect(voice, to: mixer, format: voiceFormat)
        return true
    }

    func makeMicSink() -> AVAudioSinkNode {
        let core = self
        return AVAudioSinkNode { _, frameCount, input in
            // With voice processing, the first channel holds the processed voice.
            guard let samples = input.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            core.captureMic(samples, frames: Int(frameCount))
            return 0
        }
    }

    private func makeMetronomeNode(format: AVAudioFormat) -> AVAudioSourceNode {
        let core = self
        return AVAudioSourceNode(format: format) { isSilence, _, frameCount, output in
            guard let samples = output.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            isSilence.pointee = ObjCBool(core.renderMetronome(into: samples, frames: Int(frameCount)))
            return 0
        }
    }

    private func makeVoiceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        let core = self
        return AVAudioSourceNode(format: format) { isSilence, _, frameCount, output in
            guard let samples = output.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            isSilence.pointee = ObjCBool(core.renderVoice(into: samples, frames: Int(frameCount)))
            return 0
        }
    }
}
