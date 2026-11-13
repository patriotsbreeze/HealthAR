#if os(iOS)
import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import RescueAudio
@testable import RescueCore

/// Runs the real graph in the iOS Simulator, with `xcodebuild test`. These check that the wiring
/// starts, degrades, and sequences correctly. They can't check how anything sounds.
@Suite(.serialized) struct ControllerSmokeTests {
    private final class Recorder: Sendable {
        let statuses = Mutex<[AudioStatus]>([])
        let finished = Mutex<[String]>([])
        let calls = Mutex<[Bool]>([])

        func attach(to controller: RescueAudioController) {
            controller.onStatus = { [self] status in statuses.withLock { $0.append(status) } }
            controller.onPhraseFinished = { [self] id in finished.withLock { $0.append(id) } }
            controller.onCallChanged = { [self] active in calls.withLock { $0.append(active) } }
        }

        var statusList: [AudioStatus] { statuses.withLock { $0 } }
        var finishedList: [String] { finished.withLock { $0 } }
        var callList: [Bool] { calls.withLock { $0 } }
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeController(
        texts: [String: String] = [:],
        bundle: Bundle = .main,
        micGranted: Bool = false
    ) -> (RescueAudioController, Recorder) {
        let controller = RescueAudioController(phraseTexts: texts, bundle: bundle)
        controller.micPermissionGranted = { micGranted }
        let recorder = Recorder()
        recorder.attach(to: controller)
        return (controller, recorder)
    }

    private func makeBundle(clips: [String: Double]) throws -> Bundle {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (id, seconds) in clips {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 22_050.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            let file = try AVAudioFile(forWriting: folder.appendingPathComponent(id + ".wav"), settings: settings)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
            let frames = AVAudioFrameCount(22_050 * seconds)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let data = try #require(buffer.floatChannelData?[0])
            for frame in 0..<Int(frames) { data[frame] = 0.2 * sin(Float(frame) * 0.1) }
            try file.write(from: buffer)
        }
        return try #require(Bundle(url: folder))
    }

    @Test func withoutMicPermissionItDegradesToPlaybackAndKeepsRendering() async {
        let (controller, recorder) = makeController()
        controller.start()
        let running = await waitUntil(seconds: 10) { recorder.statusList.contains(.running(.playbackOnly)) }
        #expect(running)
        #expect(recorder.statusList.contains { if case .micUnavailable = $0 { true } else { false } })
        #expect(recorder.callList == [false])

        let before = controller.core.renderCallCount
        let advanced = await waitUntil(seconds: 3) { controller.core.renderCallCount > before + 5 }
        #expect(advanced)
    }

    @Test func clipsPlayInOrderWithoutTheSynthesizer() async throws {
        let bundle = try makeBundle(clips: ["first": 0.2, "second": 0.1])
        let (controller, recorder) = makeController(texts: ["first": "One.", "second": "Two."], bundle: bundle)
        controller.start()
        controller.play(phraseID: "first")
        controller.play(phraseID: "second")
        let done = await waitUntil(seconds: 10) { recorder.finishedList.count == 2 }
        #expect(done)
        #expect(recorder.finishedList == ["first", "second"])
        #expect(!recorder.statusList.contains(.phraseUsingSpeech(id: "first")))
    }

    @Test func aMissingClipFallsBackToSpeechAndStillFinishesInOrder() async throws {
        let bundle = try makeBundle(clips: ["has_clip": 0.1])
        let texts = ["no_clip": "Push hard.", "has_clip": "Clip text."]
        let (controller, recorder) = makeController(texts: texts, bundle: bundle)
        controller.start()
        controller.play(phraseID: "no_clip")
        controller.play(phraseID: "has_clip")
        // A stall in on-device speech must not hold up the rest of the audio.
        let running = await waitUntil(seconds: 5) { recorder.statusList.contains(.running(.playbackOnly)) }
        #expect(running)
        let done = await waitUntil(seconds: 40) { recorder.finishedList.count == 2 || recorder.statusList.contains(.phraseFailed(id: "no_clip")) }
        #expect(done)
        #expect(recorder.finishedList == ["no_clip", "has_clip"])
        #expect(recorder.statusList.contains(.phraseUsingSpeech(id: "no_clip")))
        // More than the clip's 2400 samples means speech went through the engine, not around it.
        print("Speech fallback samples in ring:", controller.core.phraseRing.totalWritten)
        #expect(!recorder.statusList.contains(.phraseFailed(id: "no_clip")))
    }

    @Test func anUnknownPhraseIsReportedRatherThanSilentlyLost() async {
        let (controller, recorder) = makeController()
        controller.start()
        controller.play(phraseID: "nope")
        let reported = await waitUntil(seconds: 10) { recorder.statusList.contains(.phraseFailed(id: "nope")) }
        #expect(reported)
    }

    @Test func pauseHoldsAPhraseAndTheTimerLiftsIt() async throws {
        let bundle = try makeBundle(clips: ["held": 0.1])
        let (controller, recorder) = makeController(texts: ["held": "Held."], bundle: bundle)
        controller.start()
        _ = await waitUntil(seconds: 10) { recorder.statusList.contains(.running(.playbackOnly)) }
        controller.pause(seconds: 1)
        controller.play(phraseID: "held")
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.finishedList.isEmpty)
        let done = await waitUntil(seconds: 5) { recorder.finishedList == ["held"] }
        #expect(done)
    }

    @Test func droppingLetsThePlayingPhraseFinishAndForgetsTheRest() async throws {
        let bundle = try makeBundle(clips: ["playing": 0.4, "stale": 0.1, "must_hear": 0.1, "next": 0.1])
        let texts = ["playing": "A.", "stale": "B.", "must_hear": "C.", "next": "D."]
        let (controller, recorder) = makeController(texts: texts, bundle: bundle)
        controller.start()
        _ = await waitUntil(seconds: 10) { recorder.statusList.contains(.running(.playbackOnly)) }
        controller.play(phraseID: "playing")
        controller.play(phraseID: "stale")
        controller.play(phraseID: "must_hear")
        controller.dropQueuedPhrases(keeping: ["must_hear"])
        controller.play(phraseID: "next")
        let done = await waitUntil(seconds: 10) { recorder.finishedList.count >= 3 }
        #expect(done)
        #expect(recorder.finishedList == ["playing", "must_hear", "next"], "A dropped phrase isn't reported as played")
    }

    @Test func cuttingSilencesAPhraseAtOnceAndTheNextOneStillPlays() async throws {
        let bundle = try makeBundle(clips: ["keep_pushing": 2.0, "stand_clear": 0.1])
        let (controller, recorder) = makeController(texts: ["keep_pushing": "A.", "stand_clear": "B."], bundle: bundle)
        controller.start()
        _ = await waitUntil(seconds: 10) { recorder.statusList.contains(.running(.playbackOnly)) }
        controller.play(phraseID: "keep_pushing")
        try await Task.sleep(for: .milliseconds(200))
        let started = Date()
        controller.cutPhrases()
        controller.play(phraseID: "stand_clear")
        let done = await waitUntil(seconds: 5) { recorder.finishedList == ["stand_clear"] }
        #expect(done, "got \(recorder.finishedList)")
        #expect(Date().timeIntervalSince(started) < 1.5, "Not after the rest of a 2 s clip")
        #expect(!recorder.finishedList.contains("keep_pushing"))
    }

    @Test func modelAudioIsDroppedInPlaybackOnlyEvenWithAnOpenPolicy() async {
        let (controller, recorder) = makeController()
        controller.start()
        _ = await waitUntil(seconds: 10) { recorder.statusList.contains(.running(.playbackOnly)) }
        controller.setPolicy(RuntimePolicy(modelSpeechOpen: true, micUplink: true, frameUplink: false, audioMode: .full))
        controller.enqueueModelAudio(Data(count: 4800))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(controller.core.modelRing.totalWritten == 0)
    }

    @Test func readAloudSpeaksThroughTheEngineOrFallsBackWithoutError() async {
        let (controller, recorder) = makeController()
        controller.start()
        controller.speak(text: "This is an AI assistant. Test.")
        let written = await waitUntil(seconds: 15) { controller.core.readAloudRing.totalWritten > 0 }
        // Only records what the Simulator's speech does. Failing would need a report.
        if !written {
            try? await Task.sleep(for: .seconds(10))
            #expect(!recorder.statusList.contains(.readAloudFailed))
        }
    }

    private struct InjectedFailure: Error {}

    /// Asks for the record category, so it runs only when asked for, like the test below.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESCUE_TEST_MIC"] != nil))
    func aVoiceProcessingFailureDegradesToPlaybackWithSoundStillRunning() async throws {
        let bundle = try makeBundle(clips: ["clip": 0.1])
        let (controller, recorder) = makeController(texts: ["clip": "Clip."], bundle: bundle, micGranted: true)
        controller.enableVoiceProcessing = { _ in throw InjectedFailure() }
        controller.setMetronome(on: true)
        controller.play(phraseID: "clip")
        let running = await waitUntil(seconds: 10) { recorder.statusList.contains(.running(.playbackOnly)) }
        #expect(running)
        #expect(recorder.statusList.contains { if case .micUnavailable = $0 { true } else { false } })
        let finished = await waitUntil(seconds: 5) { recorder.finishedList == ["clip"] }
        #expect(finished)
        #expect(!recorder.statusList.contains { if case .outputLost = $0 { true } else { false } })
    }

    /// Opens the Mac's microphone through the Simulator, so it only runs when asked for, with
    /// `TEST_RUNNER_RESCUE_TEST_MIC=1`. Nothing it captures goes anywhere.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESCUE_TEST_MIC"] != nil))
    func fullModeWiring() async throws {
        let bundle = try makeBundle(clips: ["clip": 0.5])
        let (controller, recorder) = makeController(texts: ["clip": "Clip."], bundle: bundle, micGranted: true)
        controller.start()
        let running = await waitUntil(seconds: 20) {
            recorder.statusList.contains { if case .running = $0 { true } else { false } }
        }
        #expect(running)
        print("Full mode statuses:", recorder.statusList)
        guard recorder.statusList.contains(.running(.full)) else { return }
        #expect(!recorder.statusList.contains { if case .outputLost = $0 { true } else { false } })

        let mic = await waitUntil(seconds: 3) { controller.core.micRing.totalWritten > 0 }
        print("Mic samples captured:", controller.core.micRing.totalWritten)
        #expect(mic)

        let ring = controller.core.modelRing
        let chunk = Data(count: 4800)
        controller.enqueueModelAudio(chunk)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ring.totalWritten == 0)

        let open = RuntimePolicy(modelSpeechOpen: true, micUplink: true, frameUplink: false, audioMode: .full)
        controller.setPolicy(open)
        try await Task.sleep(for: .milliseconds(100))
        controller.enqueueModelAudio(chunk)
        let pushed = await waitUntil(seconds: 2) { ring.totalWritten == 2400 }
        #expect(pushed)

        // A local phrase flushes model audio, and new audio is dropped until the phrase ends.
        controller.play(phraseID: "clip")
        try await Task.sleep(for: .milliseconds(100))
        controller.enqueueModelAudio(chunk)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ring.totalWritten == 2400)
        let finished = await waitUntil(seconds: 5) { recorder.finishedList == ["clip"] }
        #expect(finished)
        // The render thread applies the flush the next time it reaches this ring.
        let flushed = await waitUntil(seconds: 1) { ring.totalRead == ring.totalWritten }
        #expect(flushed)

        controller.enqueueModelAudio(chunk)
        let resumed = await waitUntil(seconds: 2) { ring.totalWritten == 4800 }
        #expect(resumed)

        // Runaway guard: at most 20 s of audio per turn.
        let tenSeconds = Data(count: 480_000)
        controller.modelTurnEnded()
        controller.enqueueModelAudio(tenSeconds)
        controller.enqueueModelAudio(tenSeconds)
        controller.enqueueModelAudio(tenSeconds)
        let tripped = await waitUntil(seconds: 3) { recorder.statusList.contains(.runawayTurnStopped) }
        #expect(tripped)
        #expect(ring.totalWritten == 4800 + 480_000)

        // Closing drops what's buffered and refuses more.
        let closed = RuntimePolicy(modelSpeechOpen: false, micUplink: false, frameUplink: false, audioMode: .full)
        controller.setPolicy(closed)
        controller.modelTurnEnded()
        controller.enqueueModelAudio(chunk)
        try await Task.sleep(for: .milliseconds(200))
        #expect(ring.totalRead == ring.totalWritten)
        #expect(ring.totalWritten == 4800 + 480_000)

        // Back to playback only: mode changes keep the same sound running.
        controller.setMode(.playbackOnly)
        let switched = await waitUntil(seconds: 10) { recorder.statusList.last == .running(.playbackOnly) }
        #expect(switched)
        controller.setMode(.full)
        let back = await waitUntil(seconds: 10) { recorder.statusList.last == .running(.full) }
        #expect(back)
        #expect(!recorder.statusList.contains { if case .outputLost = $0 { true } else { false } })
    }
}
#endif
