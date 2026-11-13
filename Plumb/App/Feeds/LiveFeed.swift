import Observation
import PlumbCapture
import PlumbContracts
import PlumbUI
import SwiftUI

/// The camera and depth sensor. Samples are measured on the capture queue and handed to the main
/// thread in order; the hands are found automatically, or by tapping them on the picture. The ring, the
/// target line and the AED marker are drawn in the world by the capture's own view.
@MainActor
final class LiveFeed: SignalFeed {
    let name = "Camera and LiDAR"
    let isReplay = false
    let canRecord = true
    var onPictureTapped: (@MainActor () -> Void)?
    /// True from a recording the capture accepted until it is stopped here, or the capture ends it.
    private(set) var isRecording = false
    /// One more on every start and every stop. Each run of the capture has its own world and clock, so a
    /// sample or a box change from an earlier run, still on its way to the main thread, is dropped.
    private(set) var captureRun = 0

    private let capture = CaptureController()
    private let coordinator = CameraView.Coordinator()
    private let status = LiveStatus()
    private var chestMode = false
    /// True from a switch between the hands and the chest until the capture has let go of the box the other
    /// mode placed. What that box measures meanwhile belongs to the other mode, so it is dropped.
    private var awaitingClearedBox = false
    /// What the target line was last told, so the capture hears only the changes.
    private var compressing = false
    /// Set once a status has shown the recording running, so a status sent before it began cannot end it.
    private var recordingReported = false

    private init() {}

    /// Nil on a phone without LiDAR, and in the Simulator.
    static func makeIfSupported() -> SignalFeed? {
        CaptureController.isSupported ? LiveFeed() : nil
    }

    func start(deliver: @escaping @MainActor (HeightSample) -> Void) {
        // Nothing more of the run about to end is handed on, and the new run's handlers go in only once it has
        // started, so no frame measured before the restart can carry them.
        capture.onSample = nil
        capture.onSeedChanged = nil
        capture.onStatus = { [weak self] snapshot in self?.take(snapshot) }
        // A restart resets the world, so a marker from the last rescue would no longer line up.
        coordinator.clearAED()
        setChestMode(false)
        // Starting ends any recording, as the capture does.
        endRecording()
        captureRun += 1
        capture.start()
        // The restart let go of every box, whichever mode placed it.
        awaitingClearedBox = false
        compressing = false
        let run = captureRun
        // DispatchQueue.main keeps samples and box changes in the order they were measured; the analyzer drops
        // any sample out of order.
        capture.onSample = { [weak self] sample in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.captureRun == run, !self.awaitingClearedBox else { return }
                    deliver(sample)
                }
            }
        }
        capture.onSeedChanged = { [weak self] seeding in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.captureRun == run else { return }
                    self.boxChanged(seeding)
                }
            }
        }
    }

    func stop() {
        captureRun += 1
        capture.stop()
        capture.onSample = nil
        capture.onSeedChanged = nil
        endRecording()
    }

    func cameraView() -> AnyView {
        // The tap is told on through `onPictureTapped` once the capture has moved the box, in order with the samples.
        AnyView(CameraView(controller: capture, coordinator: coordinator) { [capture] point in
            capture.seed(atNormalizedImagePoint: point)
        })
    }

    func depthView() -> AnyView {
        AnyView(LiveStatusView(status: status))
    }

    func sceneSnapshot() async -> SceneSnapshot? {
        await capture.snapshot()
    }

    func placeAEDMarker(at world: SIMD3<Float>) {
        coordinator.showAED(atWorldPosition: world)
    }

    func setGuides(lock: LockState, compressing: Bool, visible: Bool) {
        coordinator.setGuides(lock: lock, compressing: compressing, visible: visible)
        // Each start of pushing makes the capture forget the heights of hands hovering before it.
        if compressing != self.compressing {
            self.compressing = compressing
            capture.setCompressing(compressing)
        }
    }

    func setChestMode(_ on: Bool) {
        guard on != chestMode else { return }
        chestMode = on
        capture.automaticSeeding = !on
        // A box already placed belongs to the other mode: the hands, or the chest. Its samples are dropped until
        // the capture says it has let go of it.
        awaitingClearedBox = true
        capture.clearSeed()
    }

    /// The capture placed, moved or cleared the box. Told in order with the samples: every sample after this
    /// one came from the box as it now stands.
    private func boxChanged(_ seeding: CaptureStatus.Seeding) {
        switch seeding {
        case .unseeded: awaitingClearedBox = false
        case .tapped: onPictureTapped?()
        case .automatic: break
        }
    }

    var stillPointNoiseMM: Double? {
        status.snapshot?.referenceNoiseMM
    }

    func setRecording(_ on: Bool) -> Bool {
        if on {
            isRecording = (try? capture.startRecording(note: "Recorded from Show working.")) != nil
            recordingReported = false
        } else {
            capture.stopRecording()
            endRecording()
        }
        return isRecording
    }

    /// Keeps the newest status, and notices a recording the capture has ended by itself, as on a full disk.
    private func take(_ snapshot: CaptureStatus) {
        status.snapshot = snapshot
        if snapshot.isRecording {
            recordingReported = isRecording
        } else if recordingReported {
            endRecording()
        }
    }

    private func endRecording() {
        isRecording = false
        recordingReported = false
    }
}

/// The newest capture status, for the show-working screen.
@MainActor
@Observable
final class LiveStatus {
    var snapshot: CaptureStatus?
}

/// What the sensors are doing right now, in plain words. Shown where the depth picture goes.
private struct LiveStatusView: View {
    let status: LiveStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.Palette.paper.color)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        // The picture column runs under the Dynamic Island, which sits on the left in this orientation.
        .padding(.leading, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.ground.color.brightness(0.03))
    }

    private var lines: [String] {
        guard let s = status.snapshot else { return ["Starting the camera."] }
        var out: [String] = []
        out.append(s.depthSupported ? "Depth sensor on" : "No depth sensor")
        out.append("Tracking \(s.tracking)")
        switch s.seeding {
        case .unseeded: out.append("Looking for the hands. Tap them to help.")
        case .tapped: out.append("Hands set by tap")
        case .automatic: out.append("Hands found automatically")
        }
        if let range = s.rangeM { out.append(String(format: "Hands %.2f m away", range)) }
        if let valid = s.handsValidFraction { out.append("Depth read on \(Int((valid * 100).rounded()))% of the hands") }
        if let noise = s.referenceNoiseMM { out.append(String(format: "Still point moves ±%.1f mm", noise)) }
        out.append("\(Int(s.framesPerSecond.rounded())) frames a second")
        out.append("Phone temperature \(s.thermal)")
        if s.isRecording { out.append("Recording") }
        return out
    }
}
