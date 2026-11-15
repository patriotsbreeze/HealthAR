import Foundation
import Observation

/// The building briefs bundled with the app, which one is in play, and whether the person said they
/// are in it this rescue. A missing or empty file means no building section at all.
@MainActor
@Observable
final class BuildingBriefStore {
    static let shared = BuildingBriefStore()
    static let resource = "building_briefs.v1"
    /// Git-ignored, for data that can't go in a public repo. Present only in a build made where it is.
    static let localResource = "building_briefs.local"

    let buildings: [BuildingBrief]
    /// Chosen by hand from the menu, so a building can be tried anywhere. Wins over everything.
    private(set) var pickedID: String?
    /// `-StagedBuilding <id>`, read in Debug builds only.
    let stagedID: String?
    @ObservationIgnored let locator: BuildingLocator?
    /// AEDs pinned by hand on this phone, added to whichever building is selected.
    @ObservationIgnored let marks: MarkedAEDStore?

    /// The rescue it was confirmed in, by `state.startedAt`, and the building it was confirmed for.
    private struct Confirmation: Equatable {
        var run: TimeInterval
        var id: String
    }

    private var confirmation: Confirmation?

    init(buildings: [BuildingBrief], stagedID: String? = nil, locator: BuildingLocator? = nil, marks: MarkedAEDStore? = nil) {
        self.buildings = buildings
        self.stagedID = stagedID
        self.locator = locator
        self.marks = marks
    }

    convenience init(bundle: Bundle = .main) {
        func usable(_ name: String) -> [BuildingBrief] {
            bundle.url(forResource: name, withExtension: "json")
                .flatMap { try? Data(contentsOf: $0) }
                .map(BuildingBrief.usable) ?? []
        }
        var staged: String?
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-StagedBuilding"), arguments.indices.contains(index + 1) {
            staged = arguments[index + 1]
        }
        #endif
        self.init(buildings: Self.merged(usable(Self.resource), local: usable(Self.localResource)), stagedID: staged, locator: .shared, marks: .shared)
    }

    /// By building id, the local file's copy winning. Bundled order first, then what only the local file has.
    static func merged(_ bundled: [BuildingBrief], local: [BuildingBrief]) -> [BuildingBrief] {
        let mine = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bundledIDs = Set(bundled.map(\.id))
        var seen = Set<String>()
        return (bundled.map { mine[$0.id] ?? $0 } + local.filter { !bundledIDs.contains($0.id) })
            .filter { seen.insert($0.id).inserted }
    }

    /// No usable building, no section.
    var showsSection: Bool { !buildings.isEmpty }

    var isPickedByHand: Bool { picked != nil }

    /// Picked by hand, else staged for a Debug run, else the one building the approximate location fits.
    var selected: BuildingBrief? {
        let found = picked ?? building(stagedID) ?? locator?.match(in: buildings)
        guard let found, let marks else { return found }
        return marks.withMarks(found)
    }

    /// The AED button's mode takes the person to be in this building, so it asks no match or confirm.
    static let aedModeName = "Rabinowitz Hall"

    /// Rabinowitz Hall with this phone's marks, else whatever would be selected, else the first building.
    /// Reads only: the dispatcher's own pick and confirmation stay as they were.
    var aedModeBuilding: BuildingBrief? {
        guard let found = buildings.first(where: { $0.name.localizedCaseInsensitiveContains(Self.aedModeName) }) else {
            return selected ?? buildings.first.map { marks?.withMarks($0) ?? $0 }
        }
        return marks?.withMarks(found) ?? found
    }

    /// Nil goes back to matching by approximate location. A new choice needs its own confirmation.
    func pick(_ id: String?) {
        guard id != pickedID else { return }
        pickedID = id
        confirmation = nil
    }

    func confirm(run: TimeInterval) {
        guard let id = selected?.id else { return }
        confirmation = Confirmation(run: run, id: id)
    }

    /// Only for the rescue it was given in, and only for the building that's still selected.
    func isConfirmed(run: TimeInterval) -> Bool {
        guard let confirmation, let id = selected?.id else { return false }
        return confirmation.run == run && confirmation.id == id
    }

    /// The building to show on the handoff card: confirmed this rescue, or nothing.
    func confirmed(run: TimeInterval) -> BuildingBrief? {
        isConfirmed(run: run) ? selected : nil
    }

    private var picked: BuildingBrief? { building(pickedID) }

    private func building(_ id: String?) -> BuildingBrief? {
        guard let id else { return nil }
        return buildings.first { $0.id == id }
    }
}
