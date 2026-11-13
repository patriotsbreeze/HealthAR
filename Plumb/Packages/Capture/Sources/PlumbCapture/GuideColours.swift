import UIKit

/// The app's colours that the camera view draws with, the same values as the UI package's
/// palette, which this package does not depend on. Each keeps its one meaning.
enum GuideColours {
    /// Marks: the ring and the target line. #F0EFEA.
    static let paper = UIColor(red: 0xF0 / 255, green: 0xEF / 255, blue: 0xEA / 255, alpha: 1)
    /// The near-black ground, behind words drawn over the picture. #0B0D11.
    static let ground = UIColor(red: 0x0B / 255, green: 0x0D / 255, blue: 0x11 / 255, alpha: 1)
    /// The AED, and nothing else. #2FC47A.
    static let aed = UIColor(red: 0x2F / 255, green: 0xC4 / 255, blue: 0x7A / 255, alpha: 1)
}
