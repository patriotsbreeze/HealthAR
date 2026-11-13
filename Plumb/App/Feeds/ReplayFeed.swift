import PlumbCapture
import PlumbContracts
import PlumbSignal
import PlumbUI
import QuartzCore
import SwiftUI

/// Plays a made-up session in real time: too shallow, corrected, a pause, good again, then hands off.
/// In chest mode it plays a made-up chest instead: rising and falling, then held still.
/// Used in the Simulator and as a demo fallback. Everything it produces is labelled as a replay.
@MainActor
final class ReplayFeed: SignalFeed {
    let name = "Replay of a made-up session"
    let isReplay = true
    let canRecord = false
    let isRecording = false
    /// A replay has no camera and no world, so nothing found in one can go stale.
    let captureRun = 0
    var onPictureTapped: (@MainActor () -> Void)?

    /// The made-up measurement noise of each story, in millimetres: what a still point would show.
    private static let storyNoiseMM = 1.5
    private static let chestNoiseMM = 0.8

    /// The rescue story, from time 0.
    private let story: [HeightSample]
    /// The chest story, from time 0.
    private let chest: [HeightSample]
    /// What is playing now, on the feed's clock.
    private var playing: [HeightSample] = []
    private var next = 0
    private var startedAt: CFTimeInterval = 0
    private var pump: Task<Void, Never>?
    private var chestMode = false

    /// The story, then ten minutes of still hands so the pause and the hand-over can be shown. The chest
    /// story is the chest check's demo, then the chest held still for as long as anyone watches.
    init(segments: [SyntheticSegment] = SyntheticSession.demo + [.pause(600)]) {
        story = SyntheticSession.samples(segments, sampleHz: 60, noiseMM: Self.storyNoiseMM, quality: 0.9, seed: 11)
        chest = SyntheticChest.samples(SyntheticChest.demo + [.still(600)], noiseMM: Self.chestNoiseMM, seed: 7)
    }

    func start(deliver: @escaping @MainActor (HeightSample) -> Void) {
        stop()
        chestMode = false
        startedAt = CACurrentMediaTime()
        play(story, from: 0)
        pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = CACurrentMediaTime() - self.startedAt
                while self.next < self.playing.count, self.playing[self.next].t <= now {
                    deliver(self.playing[self.next])
                    self.next += 1
                }
                if self.next >= self.playing.count { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
    }

    func cameraView() -> AnyView { AnyView(ReplayPicture(caption: "Replay. No camera.")) }
    func depthView() -> AnyView { AnyView(ReplayPicture(caption: "Replay. No depth picture.")) }
    func sceneSnapshot() async -> SceneSnapshot? { nil }
    func placeAEDMarker(at world: SIMD3<Float>) {}
    func setGuides(lock: LockState, compressing: Bool, visible: Bool) {}
    func setRecording(_ on: Bool) -> Bool { false }

    /// Each mode plays its own story from the beginning, carried on from the feed's present moment so
    /// time never runs backwards.
    func setChestMode(_ on: Bool) {
        guard on != chestMode else { return }
        chestMode = on
        play(on ? chest : story, from: CACurrentMediaTime() - startedAt)
    }

    var stillPointNoiseMM: Double? {
        chestMode ? Self.chestNoiseMM : Self.storyNoiseMM
    }

    private func play(_ samples: [HeightSample], from offset: TimeInterval) {
        playing = samples.map { HeightSample(t: $0.t + offset, heightMM: $0.heightMM, quality: $0.quality) }
        next = 0
    }
}

/// What stands in for the camera during a replay: the ground colour and one quiet line, nothing pretending to be video.
private struct ReplayPicture: View {
    let caption: String

    var body: some View {
        // Top right: the picture runs under the Dynamic Island, which sits on the left in this orientation.
        ZStack(alignment: .topTrailing) {
            Theme.Palette.ground.color.brightness(0.03)
            Text(caption)
                .font(.system(size: 15))
                .foregroundStyle(Theme.Palette.quietOnGround.color)
                .padding(16)
        }
    }
}
