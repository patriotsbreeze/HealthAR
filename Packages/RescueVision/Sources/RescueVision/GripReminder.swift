import Foundation

/// Two seconds of the CPR grip, the top hand coming down and lacing into the lower one, from
/// tools/make_cpr_video.py --clip. The app loops it in a corner as compressions start. Rendered from
/// MANO hands, so it carries MANO's licence: non-commercial, and kept to this private repo.
public enum GripReminder {
    public static var video: URL? { Bundle.module.url(forResource: "GripReminder", withExtension: "mp4") }
    /// The finished grip, for Reduce Motion.
    public static var still: URL? { Bundle.module.url(forResource: "GripReminder", withExtension: "png") }
}
