import Foundation
import RescueCore
import Synchronization
import simd

/// Finds objects in an image. The app bridges this to the cloud model, since this package
/// doesn't depend on RescueLive.
public protocol ObjectLocating: Sendable {
    /// Returns the box in the image as sent, or nil if not found or on any failure.
    func locate(jpeg: Data, label: String) async -> NormalizedBox?
    /// Several materials from one image, ideally in one call. Leaves out what wasn't found.
    func locate(jpeg: Data, materials: [Material]) async -> [Material: NormalizedBox]
}

extension ObjectLocating {
    /// For a locator that takes one label at a time: one call per material, in order, with the
    /// raw value as the label, as the AED has always been asked for.
    public func locate(jpeg: Data, materials: [Material]) async -> [Material: NormalizedBox] {
        var boxes: [Material: NormalizedBox] = [:]
        var asked = Set<Material>()
        for material in materials where asked.insert(material).inserted {
            if let box = await locate(jpeg: jpeg, label: material.rawValue) { boxes[material] = box }
        }
        return boxes
    }
}

/// A box normalized to the image as sent, origin top-left.
public struct NormalizedBox: Sendable, Equatable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    /// Nil for a box that can't be real, because this comes from a model.
    public init?(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        guard minX >= 0, minY >= 0, maxX <= 1, maxY <= 1, minX < maxX, minY < maxY else { return nil }
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    var center: SIMD2<Double> { [(minX + maxX) / 2, (minY + maxY) / 2] }

    /// Going round from the top-left.
    var corners: [SIMD2<Double>] { [[minX, minY], [maxX, minY], [maxX, maxY], [minX, maxY]] }
}

public enum LocateStatus: String, Sendable, Equatable {
    case idle, locating, located
    case notFound = "not_found"
    case noSurface = "no_surface"
    case unreliablePose = "unreliable_pose"
}

/// The AED was the only thing located before materials were, and the app still names it so.
public typealias AEDStatus = LocateStatus

/// A JPEG and the camera pose it was captured with, frozen together.
struct FrozenFrame: Sendable {
    var jpeg: Data
    var record: FrameRecord
    var rotation: CaptureRotation
}

/// Where a located material is in the world.
struct PlacedObject: Sendable, Equatable {
    var world: SIMD3<Float>
    /// The box's corners on the plane through `world` that faces the camera that saw it. Nil when
    /// a corner's ray doesn't reach that plane.
    var corners: [SIMD3<Float>]?
    var placedAt: TimeInterval
    /// Times located in a row at about this spot, counting this one.
    var sightings = 1
}

/// Places objects in the world from late answers about old frames, one entry per material.
final class ObjectLocator: Sendable {
    /// A towel or pillow gets picked up and moved, so a callout to where one was seen doesn't
    /// outlast this. An AED stays put and keeps its point.
    static let movableSeconds: TimeInterval = 60
    /// A movable point is asked for again this long after it was placed, while it still shows, so a
    /// same-spot answer lands before it runs out and the callout of a towel still in view never blinks.
    static let refreshSeconds: TimeInterval = 45
    /// One sighting can be a wrong label, and people follow a callout. Two at about the same spot
    /// before one shows.
    static let sightingsToShow = 2
    /// Metres. Two sightings closer than this are the same object.
    static let sameSpot: Float = 0.5

    private struct Entry {
        var requestID: UInt64 = 0
        var status = LocateStatus.idle
        var placed: PlacedObject?
        var carries = false
    }

    private struct State {
        /// Shared by every material, so an id from before `clear()` never matches a later one.
        var lastRequestID: UInt64 = 0
        var entries: [Material: Entry] = [:]
    }

    private let state = Mutex(State())
    private let locator: any ObjectLocating
    private let clock: @Sendable () -> TimeInterval
    private let surface: @Sendable (WorldRay) async -> SIMD3<Float>?

    /// - Parameter surface: Where a world ray first meets a real surface.
    init(
        locator: any ObjectLocating,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        surface: @escaping @Sendable (WorldRay) async -> SIMD3<Float>?
    ) {
        self.locator = locator
        self.clock = clock
        self.surface = surface
    }

    func worldPoint(_ material: Material) -> SIMD3<Float>? {
        let now = clock()
        return state.withLock { Self.current($0.entries[material], material, at: now)?.world }
    }

    /// The AED's point, if any locate since the last clear that placed one was told it carries.
    /// Nothing else is carried into a later arrest.
    func carriedPoint(_ material: Material) -> SIMD3<Float>? {
        guard material.isFixed else { return nil }
        return state.withLock { state in
            guard let entry = state.entries[material], entry.carries else { return nil }
            return entry.placed?.world
        }
    }

    /// Idle again once a movable material's point is due a refresh, so it is looked for afresh while
    /// its callout still shows. A same-spot answer then counts on from it.
    func status(_ material: Material) -> LocateStatus {
        let now = clock()
        return state.withLock { state in
            guard let entry = state.entries[material] else { return .idle }
            if entry.status == .located, !material.isFixed,
               entry.placed.map({ now - $0.placedAt >= Self.refreshSeconds }) ?? true {
                return .idle
            }
            return entry.status
        }
    }

    func sightings(_ material: Material) -> Int {
        let now = clock()
        return state.withLock { Self.current($0.entries[material], material, at: now)?.sightings ?? 0 }
    }

    /// Movable materials seen often enough, recently enough, to point at. The AED has its own arrow.
    func callouts() -> [Material: PlacedObject] {
        let now = clock()
        return state.withLock { state in
            var shown: [Material: PlacedObject] = [:]
            for (material, entry) in state.entries where !material.isFixed {
                if let placed = Self.current(entry, material, at: now), placed.sightings >= Self.sightingsToShow {
                    shown[material] = placed
                }
            }
            return shown
        }
    }

    /// Forgets every point and drops every answer still on its way.
    func clear() {
        state.withLock { $0.entries = [:] }
    }

    /// The id for one frame's request. Taking it voids any answer still on its way for these
    /// materials and no others, so a newer pillow request leaves the towel's answer alone.
    func beginRequest(for materials: Set<Material>) -> UInt64 {
        state.withLock { state in
            state.lastRequestID += 1
            for material in materials {
                state.entries[material, default: Entry()].requestID = state.lastRequestID
                state.entries[material]?.status = .locating
            }
            return state.lastRequestID
        }
    }

    func locate(_ frozen: FrozenFrame, materials: Set<Material>, carries: Bool = false) async {
        await locate(frozen, materials: materials, carries: carries, requestID: beginRequest(for: materials))
    }

    /// - Parameter carries: For the AED only, which an awake scan remembers for a later arrest.
    func locate(_ frozen: FrozenFrame, materials: Set<Material>, carries: Bool, requestID: UInt64) async {
        let asked = Material.allCases.filter(materials.contains)
        guard !asked.isEmpty else { return }
        guard frozen.record.tracking == .normal else {
            for material in asked { finish(material, requestID, status: .unreliablePose) }
            return
        }

        let boxes = await locator.locate(jpeg: frozen.jpeg, materials: asked)
        for material in asked {
            guard let box = boxes[material] else {
                finish(material, requestID, status: .notFound)
                continue
            }
            // The answer is seconds late and the phone has moved, so the ray must come from the
            // pose stored with this frame and never from the current camera.
            let point = frozen.rotation.captureNormalized(fromDisplay: box.center)
            let ray = frozen.record.pose.ray(throughImagePoint: point)
            guard let hit = await surface(ray) else {
                finish(material, requestID, status: .noSurface)
                continue
            }
            finish(
                material,
                requestID,
                status: .located,
                point: hit,
                corners: Self.corners(of: box, in: frozen, through: hit),
                carries: carries && material.isFixed
            )
        }
    }

    /// Each corner's ray, also from the stored pose, meets the plane through the hit that faces
    /// that camera. Coarse, but enough for brackets, and it costs no more raycasts.
    static func corners(of box: NormalizedBox, in frozen: FrozenFrame, through hit: SIMD3<Float>) -> [SIMD3<Float>]? {
        let pose = frozen.record.pose
        let forward = -simd_normalize(pose.transform.columns.2.xyz)
        var corners: [SIMD3<Float>] = []
        for corner in box.corners {
            let ray = pose.ray(throughImagePoint: frozen.rotation.captureNormalized(fromDisplay: corner))
            let facing = simd_dot(ray.direction, forward)
            guard facing > 1e-3 else { return nil }
            let distance = simd_dot(hit - ray.origin, forward) / facing
            guard distance > 0 else { return nil }
            corners.append(ray.origin + ray.direction * distance)
        }
        return corners
    }

    private static func current(_ entry: Entry?, _ material: Material, at now: TimeInterval) -> PlacedObject? {
        guard let placed = entry?.placed else { return nil }
        if material.isFixed { return placed }
        return now - placed.placedAt < movableSeconds ? placed : nil
    }

    /// An earlier good point survives a later miss, because an AED doesn't move and a towel's
    /// time runs out anyway. A point that carried still does when found again, or a scan in
    /// compressions would take the arrow away.
    private func finish(
        _ material: Material,
        _ requestID: UInt64,
        status: LocateStatus,
        point: SIMD3<Float>? = nil,
        corners: [SIMD3<Float>]? = nil,
        carries: Bool = false
    ) {
        let now = clock()
        state.withLock { state in
            guard var entry = state.entries[material], entry.requestID == requestID else { return }
            entry.status = status
            if let point {
                let previous = Self.current(entry, material, at: now)
                let sameSpot = previous.map { simd_distance($0.world, point) <= Self.sameSpot } ?? false
                entry.placed = PlacedObject(
                    world: point,
                    corners: corners,
                    placedAt: now,
                    sightings: sameSpot ? (previous?.sightings ?? 0) + 1 : 1
                )
                entry.carries = entry.carries || carries
            }
            state.entries[material] = entry
        }
    }
}
