import AVFAudio
import Foundation

enum PCMConversionError: Error {
    case cannotConvert(String)
}

/// A serial wrapper over `AVAudioConverter`. Allocates, so it never runs on the render thread.
final class PCMConverter: @unchecked Sendable {
    // The input block is `@Sendable`, but the converter calls it synchronously during `convert`.
    private final class InputSlot: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        var endOfStream = false
    }

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.downmix = true
        self.converter = converter
        outputFormat = output
    }

    /// Calls `emit` with each batch of output, valid only during the call. Without `endOfStream` the
    /// converter keeps its filter state, so the next input continues seamlessly.
    func convert(_ input: AVAudioPCMBuffer, endOfStream: Bool = false, emit: (AVAudioPCMBuffer) -> Void) {
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        let slot = InputSlot()
        slot.buffer = input
        slot.endOfStream = endOfStream
        var status: AVAudioConverterOutputStatus
        repeat {
            var error: NSError?
            status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let buffer = slot.buffer {
                    slot.buffer = nil
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = slot.endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if output.frameLength > 0 { emit(output) }
        } while status == .haveData
    }
}

/// The format of the voice source node: 24 kHz mono floats.
func makeVoiceFormat() -> AVAudioFormat? {
    AVAudioFormat(standardFormatWithSampleRate: Double(RenderCore.voiceSampleRate), channels: 1)
}

/// Reads a whole audio file into memory as voice-format samples, so playback needs no disk I/O.
func decodeClip(at url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
        let format = makeVoiceFormat(),
        let converter = PCMConverter(from: file.processingFormat, to: format)
    else {
        throw PCMConversionError.cannotConvert(url.lastPathComponent)
    }
    try file.read(into: input)

    var samples: [Float] = []
    converter.convert(input, endOfStream: true) { samples.append(contentsOf: $0.firstChannelFloats) }
    guard !samples.isEmpty else { throw PCMConversionError.cannotConvert(url.lastPathComponent) }
    return samples
}

extension AVAudioPCMBuffer {
    fileprivate var firstChannelFloats: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: floatChannelData?[0], count: Int(frameLength))
    }
}

/// Converts the buffers one on-device utterance produces, whose format depends on the voice.
/// The synthesizer calls back serially, and the converter keeps filter state between buffers.
final class VoiceBufferConverter: @unchecked Sendable {
    private var converter: PCMConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, let voiceFormat = makeVoiceFormat() else { return [] }
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = PCMConverter(from: buffer.format, to: voiceFormat)
        }
        var samples: [Float] = []
        converter?.convert(buffer) { samples.append(contentsOf: $0.firstChannelFloats) }
        return samples
    }
}

/// Drains the mic ring and returns 16 kHz Int16 samples, ready for the VAD.
final class MicResampler: @unchecked Sendable {
    private static let batchFrames: AVAudioFrameCount = 8192

    private let input: AVAudioPCMBuffer
    private let converter: PCMConverter

    init?(inputSampleRate: Double) {
        guard
            inputSampleRate > 0,
            let inputFormat = AVAudioFormat(standardFormatWithSampleRate: inputSampleRate, channels: 1),
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
            let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: Self.batchFrames),
            let converter = PCMConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        self.input = input
        self.converter = converter
    }

    func drain(_ ring: SPSCRingBuffer) -> [Int16] {
        guard let channel = input.floatChannelData?[0] else { return [] }
        var samples: [Int16] = []
        while true {
            let count = ring.pop(into: channel, count: Int(Self.batchFrames))
            guard count > 0 else { return samples }
            input.frameLength = AVAudioFrameCount(count)
            converter.convert(input) { output in
                guard let pcm = output.int16ChannelData?[0] else { return }
                samples.append(contentsOf: UnsafeBufferPointer(start: pcm, count: Int(output.frameLength)))
            }
        }
    }
}
