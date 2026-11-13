import PlumbCapture
import PlumbContracts
import SwiftUI

/// Where hand-height samples come from: the camera and depth sensor, or a replay of a known session.
@MainActor
protocol SignalFeed: AnyObject {
    /// Plain words for the show-working view, for example "Camera and LiDAR" or "Replay".
    var name: String { get }
    /// True when the samples are made up rather than measured. Shown wherever it matters.
    var isReplay: Bool { get }
    /// Starts delivering samples on the main thread, in time order, with times in seconds since `start`.
    /// Always starts by measuring the hands, never in chest mode.
    func start(deliver: @escaping @MainActor (HeightSample) -> Void)
    func stop()
    /// The picture for the left of the rescue and chest screens.
    func cameraView() -> AnyView
    /// The picture for the left of the show-working screen.
    func depthView() -> AnyView
    /// Called once a tap on the picture has moved the measuring box there, in order with the samples: every
    /// sample delivered after it comes from the new box. Not called for a tap that placed nothing.
    var onPictureTapped: (@MainActor () -> Void)? { get set }

    /// Changes whenever the world the camera measures in starts over, as on every `start` and `stop`. A
    /// point found in one world means nothing in the next, so read it before asking for a still and
    /// place a marker only while it has not changed.
    var captureRun: Int { get }
    /// One still with its depth, for the AED finder. Nil when there is no camera.
    func sceneSnapshot() async -> SceneSnapshot?
    /// Shows the AED marker at a point in the world, replacing any earlier one.
    func placeAEDMarker(at world: SIMD3<Float>)

    /// Says what the guides drawn in the world over the chest should show; called on every tick. The ring
    /// shows where the hands are measured, the target line only while `compressing`, and neither when
    /// `visible` is false.
    func setGuides(lock: LockState, compressing: Bool, visible: Bool)

    /// Switches between measuring the hands for a rescue and watching a chest for the chest check. In
    /// chest mode the measuring box is placed only by a tap, never found by itself.
    func setChestMode(_ on: Bool)
    /// How much a point that should be still appears to move, in millimetres: under this a change is
    /// only noise. Nil until it is known.
    var stillPointNoiseMM: Double? { get }

    /// True when what the sensors measure can be recorded to a file, for a replay on a Mac.
    var canRecord: Bool { get }
    /// True while measurements are being recorded. Goes false by itself when recording ends on its own.
    var isRecording: Bool { get }
    /// Starts or stops recording, and returns whether it is recording now.
    func setRecording(_ on: Bool) -> Bool
}

/// Picks the feed: the real sensors when the phone has them, otherwise a labelled replay.
@MainActor
enum FeedChoice {
    /// Launch with `-replay` to force the replay on a phone that has the sensors.
    static func make() -> SignalFeed {
        let forced = ProcessInfo.processInfo.arguments.contains("-replay")
        if !forced, let live = LiveFeed.makeIfSupported() { return live }
        return ReplayFeed()
    }
}
