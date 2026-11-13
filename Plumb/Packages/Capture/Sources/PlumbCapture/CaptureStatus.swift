import CoreGraphics
import Foundation

/// A small picture of how capture is going, published a few times a second for the "show working" view.
///
/// Rectangles are in normalised image coordinates: 0...1 across the camera's landscape picture,
/// origin at its top-left, the same space `CameraView` reports taps in.
public struct CaptureStatus: Sendable, Equatable {
    /// How the hands box was placed, if it was.
    public enum Seeding: String, Sendable, Equatable {
        /// No hands box yet: nothing is being measured.
        case unseeded
        /// Placed where someone tapped the picture.
        case tapped
        /// Placed from the body pose Vision found.
        case automatic
    }

    /// True when this phone's LiDAR gives a depth map. Without it nothing can be measured.
    public var depthSupported: Bool
    /// World tracking as one plain word, such as "normal", "starting" or "moving".
    public var tracking: String
    /// Whether the hands box is placed, and how.
    public var seeding: Seeding
    /// Straight-line distance from the camera to the hands, in metres. Nil until it has been read.
    public var rangeM: Double?
    /// Share of the hands patch the hands fill, 0...1. Nil when there was no hands patch.
    public var handsValidFraction: Double?
    /// How much the still reference appears to move, in millimetres: the live noise floor.
    /// Nil while there is no reference.
    public var referenceNoiseMM: Double?
    /// Camera frames actually processed per second.
    public var framesPerSecond: Double
    /// Where the hands box appears in the picture. Nil when unseeded or out of view.
    public var handsRect: CGRect?
    /// Where the reference square appears in the picture. Nil until a reference is chosen.
    public var referenceRect: CGRect?
    /// The phone's thermal state as one plain word: "nominal", "fair", "serious" or "critical".
    public var thermal: String
    /// True while frames are being recorded to a trace file.
    public var isRecording: Bool

    /// Builds a status; everything not given reads as "nothing yet".
    public init(depthSupported: Bool, tracking: String, seeding: Seeding = .unseeded, rangeM: Double? = nil,
                handsValidFraction: Double? = nil, referenceNoiseMM: Double? = nil, framesPerSecond: Double = 0,
                handsRect: CGRect? = nil, referenceRect: CGRect? = nil, thermal: String, isRecording: Bool = false) {
        self.depthSupported = depthSupported
        self.tracking = tracking
        self.seeding = seeding
        self.rangeM = rangeM
        self.handsValidFraction = handsValidFraction
        self.referenceNoiseMM = referenceNoiseMM
        self.framesPerSecond = framesPerSecond
        self.handsRect = handsRect
        self.referenceRect = referenceRect
        self.thermal = thermal
        self.isRecording = isRecording
    }
}
