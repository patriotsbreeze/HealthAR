import AVFoundation
import Foundation
import Testing
@testable import PlumbAgents

@Suite struct BufferConverterTests {
    private func tone(sampleRate: Double, channels: AVAudioChannelCount, frames: Int) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames {
                data[channel][frame] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            }
        }
        return buffer
    }

    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    @Test func microphoneAudioComesOutInTheRecognizersFormat() throws {
        let microphone = try tone(sampleRate: 48_000, channels: 1, frames: 4_800)
        let converter = try #require(BufferConverter(from: microphone.format, to: speechFormat))

        var frames = 0
        for _ in 0..<10 {
            let converted = try #require(converter.convert(microphone))
            #expect(converted.format == speechFormat)
            frames += Int(converted.frameLength)
        }

        // A second of audio is about 16,000 frames. The resampler's filter holds a few tens of
        // milliseconds inside it, which only matters for the very end of a question.
        #expect(frames <= 16_100)
        #expect(frames > 15_400)
    }

    @Test func stereoAtAnotherRateIsMixedDown() throws {
        let microphone = try tone(sampleRate: 44_100, channels: 2, frames: 4_410)
        let converter = try #require(BufferConverter(from: microphone.format, to: speechFormat))

        let converted = try #require(converter.convert(microphone))

        #expect(converted.format.channelCount == 1)
        #expect(converted.frameLength > 1_400)
    }

    @Test func everyResultIsABufferOfItsOwn() throws {
        let microphone = try tone(sampleRate: 16_000, channels: 1, frames: 1_600)
        let converter = try #require(BufferConverter(from: microphone.format, to: microphone.format))

        let first = try #require(converter.convert(microphone))
        let second = try #require(converter.convert(microphone))

        #expect(first !== microphone)
        #expect(first !== second)
    }

    @Test func anEmptyBufferGivesNothing() throws {
        let empty = try tone(sampleRate: 48_000, channels: 1, frames: 0)
        let converter = try #require(BufferConverter(from: empty.format, to: speechFormat))

        #expect(converter.convert(empty) == nil)
    }
}

@Suite struct HeardTextTests {
    @Test func finishedPiecesAreJoinedWithSpaces() {
        let heard = HeardText()

        heard.append("How fast")
        heard.append(" am I going? ")

        #expect(heard.text == "How fast am I going?")
    }

    @Test func aWholeTextReplacesTheLastOne() {
        let heard = HeardText()

        heard.replace(with: "How")
        heard.replace(with: "How deep")

        #expect(heard.text == "How deep")
    }

    @Test func nothingButSpaceIsNothingHeard() {
        let heard = HeardText()

        heard.append("  ")

        #expect(heard.text == nil)
    }

    @Test func nothingChangesOnceFinished() {
        let heard = HeardText()

        heard.replace(with: "How deep")
        heard.finish()
        heard.replace(with: "something late")
        heard.append("and more")

        #expect(heard.text == "How deep")
    }

    @Test func waitersWakeWhenFinished() async {
        let heard = HeardText()
        let woke = Locked(false)
        let waiting = Task {
            await heard.waitUntilFinished()
            woke.with { $0 = true }
        }

        try? await Task.sleep(for: .milliseconds(20))
        #expect(!woke.current)
        heard.finish()
        await waiting.value

        #expect(woke.current)
        // Waiting after the end returns at once.
        await heard.waitUntilFinished()
    }
}

@MainActor
@Suite struct OnDeviceTranscriberTests {
    @Test func listeningCannotStartBeforeARecognizerIsFound() {
        let transcriber = OnDeviceTranscriber()

        #expect(throws: OnDeviceTranscriber.Failure.notReady(reason: "Speech recognition has not been set up yet.")) {
            try transcriber.begin()
        }
    }

    @Test func finishingWithoutListeningHearsNothing() async {
        #expect(await OnDeviceTranscriber().finish() == nil)
    }
}
