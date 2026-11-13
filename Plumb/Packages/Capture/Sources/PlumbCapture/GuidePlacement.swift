import Foundation

/// Where the guides stand in the world on the newest frame: worked out on the capture queue from
/// the hands box and the depth map, and read on the main thread to move the entities that draw them.
/// Whether each is shown is the app's call (`GuideState`); this only says where it would go.
struct GuidePlacement: Sendable, Equatable {
    /// The ring on the chest. Nil while there is no hands box.
    var ring: RingPlacement?
    /// The target line. Nil until the top of the stroke is known.
    var line: LinePlacement?

    /// Nothing placed.
    static let none = GuidePlacement()
}
