import Testing
@testable import RescueAudio

private func renderVoice(_ core: RenderCore, frames: Int) -> [Float] {
    var output = [Float](repeating: 9, count: frames)
    output.withUnsafeMutableBufferPointer { _ = core.renderVoice(into: $0.baseAddress!, frames: frames) }
    return output
}

@Suite struct AwakeModelAudioTests {
    /// The phrase ring runs dry between two phrases, and a word of the answer mustn't come through.
    @Test func heldModelAudioWaitsThroughTheGapBetweenPhrases() {
        let core = RenderCore()
        defer { core.deallocate() }
        core.setModelHeld(true)
        core.modelRing.push([3, 3, 3])
        core.phraseRing.push([1, 1])
        #expect(renderVoice(core, frames: 4) == [1, 1, 0, 0])
        #expect(core.modelRing.totalRead == 0)

        core.phraseRing.push([2])
        #expect(renderVoice(core, frames: 2) == [2, 0])

        core.setModelHeld(false)
        #expect(renderVoice(core, frames: 4) == [3, 3, 3, 0], "and none of it was lost")
    }

    @Test func notHeldItFollowsThePhraseAsItAlwaysHas() {
        let core = RenderCore()
        defer { core.deallocate() }
        core.modelRing.push([3, 3])
        core.phraseRing.push([1])
        #expect(renderVoice(core, frames: 3) == [1, 3, 3])
    }
}

#if os(iOS)
import AVFAudio
import Foundation
@testable import RescueCore
import Synchronization

/// The real controller in the iOS Simulator, with the gate opened by hand, since the policy only opens
/// it in full mode and that takes the Mac's microphone. `ControllerSmokeTests.fullModeWiring` is that
/// run, for the arrest path.
@Suite(.serialized) struct AwakeModelAudioControllerTests {
    private func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func oneSecondClip() throws -> Bundle {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 22_050.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent("clip.wav"), settings: settings)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
        buffer.frameLength = 22_050
        try file.write(from: buffer)
        return try #require(Bundle(url: folder))
    }

    private final class Finished: Sendable {
        let ids = Mutex<[String]>([])
        var list: [String] { ids.withLock { $0 } }
    }

    /// A controller with a phrase just begun, and the model gate open.
    private func playing(waits: Bool) async throws -> (RescueAudioController, Finished) {
        let controller = RescueAudioController(phraseTexts: ["clip": "Clip."], bundle: try oneSecondClip())
        controller.micPermissionGranted = { false }
        let finished = Finished()
        controller.onPhraseFinished = { id in finished.ids.withLock { $0.append(id) } }
        var policy = RuntimePolicy(modelSpeechOpen: true, micUplink: false, frameUplink: false, audioMode: .playbackOnly)
        policy.modelAudioWaitsForPhrases = waits
        controller.setPolicy(policy)
        controller.start()
        let running = await waitUntil(seconds: 10) { controller.core.renderCallCount > 5 }
        #expect(running)
        try await Task.sleep(for: .milliseconds(200))
        controller.gate.setOpen(true)
        controller.play(phraseID: "clip")
        try await Task.sleep(for: .milliseconds(100))
        return (controller, finished)
    }

    @Test func anAnswerArrivingDuringAPhrasePlaysAfterIt() async throws {
        let (controller, finished) = try await playing(waits: true)
        let ring = controller.core.modelRing
        controller.enqueueModelAudio(Data(count: 4800))
        let held = await waitUntil(seconds: 0.5) { ring.totalWritten == 2400 }
        #expect(held, "pushed, not dropped")
        #expect(ring.totalRead == 0, "and it waits")

        let said = await waitUntil(seconds: 5) { finished.list == ["clip"] }
        #expect(said)
        let played = await waitUntil(seconds: 2) { ring.totalRead == 2400 }
        #expect(played, "all of it, once the phrase is done")
    }

    /// The arrest path, where this would replay stale speech after a required step.
    @Test func withoutThePolicyItIsDropped() async throws {
        let (controller, finished) = try await playing(waits: false)
        let ring = controller.core.modelRing
        controller.enqueueModelAudio(Data(count: 4800))
        try await Task.sleep(for: .milliseconds(200))
        #expect(ring.totalWritten == 0)
        let said = await waitUntil(seconds: 5) { finished.list == ["clip"] }
        #expect(said)

        controller.enqueueModelAudio(Data(count: 4800))
        let pushed = await waitUntil(seconds: 2) { ring.totalWritten == 2400 }
        #expect(pushed, "so the first one was the phrase's doing")
    }
}
#endif
