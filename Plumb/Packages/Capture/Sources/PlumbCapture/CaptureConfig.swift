import Foundation
import PlumbGeometry

/// Every tunable number of the capture side, in one place, with the defaults it ships with.
/// The defaults assume an iPhone Pro propped about a metre from the rescuer.
public struct CaptureConfig: Sendable, Equatable {

    // MARK: The hands box

    /// Width of the box fixed in the world that the hands move up and down in, in metres. Default 0.14.
    public var handsWidthM = 0.14
    /// Height of that box, in metres; tall enough for a whole stroke and some drift. Default 0.24.
    public var handsHeightM = 0.24
    /// Most depth-map cells across the hands patch. Default 32; at 1 m the box needs about 28.
    public var handsMaxColumns = 32
    /// Most depth-map rows in the hands patch. Default 48; at 1 m the box needs about 47.
    /// Nearer than that the patch keeps only the middle of the box.
    public var handsMaxRows = 48
    /// Fewest depth-map cells along either side of any patch, so a far box still holds a few. Default 4.
    public var minPatchCells = 4
    /// Columns of the brightness grid laid over the hands box. Default 32.
    public var lumaColumns = 32
    /// Rows of the brightness grid; many, because the image-plane method slides along them. Default 96.
    public var lumaRows = 96

    // MARK: The reference

    /// How far to the side of the hands the still reference sits, level with them, in metres. Default 0.25.
    public var referenceOffsetM = 0.25
    /// Side of the square read around the reference, in metres. Default 0.08.
    public var referenceSizeM = 0.08
    /// Most depth-map cells along either side of the reference patch. Default 16.
    public var referenceMaxCells = 16
    /// Seconds both candidate sides are watched before the steadier one is kept. Default 0.5.
    public var referenceTrialS: TimeInterval = 0.5
    /// Depth readings a side needs during that watch before it may be chosen. Default 8.
    public var referenceTrialMinReadings = 8

    // MARK: Seeding

    /// Side, in depth-map cells, of the small window read around a tapped or detected point. Default 7,
    /// about 5 cm at a metre.
    public var probeCells = 7
    /// Lowest LiDAR confidence used when reading the depth at a tapped or detected point
    /// (0 low, 1 medium, 2 high). Default 1.
    public var probeMinConfidence: UInt8 = 1
    /// Most body pose searches started per second. Default 5. Must be above 0.
    public var bodySearchesPerSecond = 5.0
    /// People whose wrists read farther than this in the depth map are bystanders, in metres. Default 2.
    public var bystanderRangeM = 2.0
    /// The wrists must be this close to each other in the world before the hands are seeded,
    /// in metres. Default 0.15.
    public var wristsTogetherM = 0.15
    /// How far past the wrists the hands sit, as a share of the elbow-to-wrist length in the image.
    /// Default 0.35: a palm's width beyond the wrist for a typical forearm.
    public var handsBeyondWristShare = 0.35
    /// Lowest confidence Vision must give a joint for it to be used, 0...1. Default 0.3.
    public var minJointConfidence = 0.3
    /// Seconds without a valid reading after which the hands are sought again automatically. Default 2.
    public var reseedAfterS: TimeInterval = 2
    /// Lowest sample quality that counts as a valid reading of the hands. Default 0.2.
    public var validQuality = 0.2

    // MARK: Guides

    /// Whether to ask for people occlusion, so arms pass in front of the ring, the target line and
    /// the AED marker. Switched on only where the phone supports it together with the depth map. Default true.
    public var peopleOcclusion = true
    /// Radius around the hands box centre whose depths the ring's surface is fitted to, in metres. Default 0.06.
    public var ringFitRadiusM = 0.06
    /// Most depth-map cells along either side of the window read for that fit. Default 32.
    public var ringFitMaxCells = 32
    /// Fewest depth readings the fit needs; with fewer the ring lies level. Default 30.
    public var ringFitMinPoints = 30
    /// Furthest the fitted surface may lean from level before the ring lies level instead, in
    /// radians. Default 0.6, about 35 degrees: a chest lying down, with room for a sagging cushion.
    public var ringMaxTiltRadians = 0.6
    /// Furthest the depths may stray, root mean square, from the fitted surface before the ring lies
    /// level instead, in metres. Default 0.006: LiDAR noise on one surface, not a hand on a chest.
    public var ringMaxRoughnessM = 0.006
    /// Seconds of hands heights the top of the stroke is the highest of. Default 1.5: more than
    /// two strokes even at 100 a minute.
    public var restTopSpanS: TimeInterval = 1.5
    /// Seconds of readings each hands height is steadied over, by their median, before the top is
    /// taken. Default 0.1: several frames, far shorter than a stroke.
    public var restTopSteadyS: TimeInterval = 0.1
    /// Fewest steadied heights in that span before the top, and with it the target line, is trusted. Default 10.
    public var restTopMinReadings = 10
    /// How much nearer the camera than the target the line is drawn, along the target's line of
    /// sight, in metres. The picture shows it in the same place; it keeps the line in front of the
    /// hands rather than inside them. Default 0.04.
    public var lineTowardCameraM = 0.04
    /// Furthest the hands' rest point may lie from the hands box centre along the line of sight, in
    /// metres; beyond it the line stands straight above or below the centre instead. Default 0.3.
    public var lineMaxSlideM = 0.3

    // MARK: Scene snapshots

    /// Longest wait, in seconds, for a frame with depth and normal tracking when a scene snapshot
    /// is asked for. Default 1.
    public var snapshotTimeoutS: TimeInterval = 1

    // MARK: Reporting

    /// Status snapshots published per second. Default 5. Must be above 0.
    public var statusPerSecond = 5.0

    /// The height estimators' own numbers. Default: their documented defaults.
    public var estimator = HeightEstimator.Config()

    /// Builds a config with every value at its documented default.
    public init() {}
}
