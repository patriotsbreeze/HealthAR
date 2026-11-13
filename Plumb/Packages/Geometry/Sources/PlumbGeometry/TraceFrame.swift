import Foundation

/// Everything the height estimators need from one camera frame, small enough to record.
///
/// The capture side fills this from ARKit; a recorded trace replays the same values later.
public struct TraceFrame: Sendable, Codable, Equatable {
    /// Seconds since the session started, from the camera frame's own timestamp.
    public var t: TimeInterval
    /// Lens values of the captured image this frame's pixel coordinates refer to.
    public var intrinsics: Intrinsics
    /// Where the camera was when the frame was taken.
    public var pose: CameraPose
    /// True while world tracking reports its normal state.
    public var trackingNormal: Bool
    /// The u coordinate, in image pixels, of the centre of the hands in this frame.
    /// It should follow the hands from frame to frame; the along-ray height is read at this pixel.
    public var handsU: Double
    /// The v coordinate, in image pixels, of the centre of the hands in this frame.
    public var handsV: Double
    /// Depth samples over the hands and their surroundings, big enough that the hands stay
    /// inside through a whole stroke. Nil when there was no depth this frame.
    public var hands: DepthPatch?
    /// Brightness samples over the hands, on a grid lined up with world-up. Nil when there was
    /// none this frame.
    public var handsLuma: LumaPatch?
    /// The u coordinate of the centre of the luma grid, in image pixels. Report it whenever the
    /// grid can move between frames; when nil the grid is taken to stay where it was.
    public var handsLumaU: Double?
    /// The v coordinate of the centre of the luma grid, in image pixels.
    public var handsLumaV: Double?
    /// The u coordinate of the centre of the reference patch, in image pixels.
    public var referenceU: Double?
    /// The v coordinate of the centre of the reference patch, in image pixels.
    public var referenceV: Double?
    /// Depth samples on something that does not move, such as the floor or the edge of the torso.
    public var reference: DepthPatch?

    /// Builds a frame; the patches and the reference are optional.
    public init(t: TimeInterval, intrinsics: Intrinsics, pose: CameraPose, trackingNormal: Bool,
                handsU: Double, handsV: Double, hands: DepthPatch? = nil, handsLuma: LumaPatch? = nil,
                handsLumaU: Double? = nil, handsLumaV: Double? = nil,
                referenceU: Double? = nil, referenceV: Double? = nil, reference: DepthPatch? = nil) {
        self.t = t
        self.intrinsics = intrinsics
        self.pose = pose
        self.trackingNormal = trackingNormal
        self.handsU = handsU
        self.handsV = handsV
        self.hands = hands
        self.handsLuma = handsLuma
        self.handsLumaU = handsLumaU
        self.handsLumaV = handsLumaV
        self.referenceU = referenceU
        self.referenceV = referenceV
        self.reference = reference
    }
}

/// The first line of a trace file: what the recording is and where it came from.
public struct TraceHeader: Sendable, Codable, Equatable {
    /// Format version of the file. See `TraceFile.currentVersion`.
    public var version: Int
    /// When the recording started, kept to the whole second.
    public var createdAt: Date
    /// The device that made it, for example "iPhone16,1".
    public var device: String
    /// Free text about the recording: the setup, the surface, who pressed.
    public var note: String

    /// Builds a header for a new recording in the current format.
    public init(version: Int = TraceFile.currentVersion, createdAt: Date, device: String, note: String) {
        self.version = version
        self.createdAt = createdAt
        self.device = device
        self.note = note
    }
}
