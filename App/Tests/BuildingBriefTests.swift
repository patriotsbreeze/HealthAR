import CoreLocation
import Foundation
@testable import HealthAISim
import Testing

/// Made up for these tests only. No bundled file carries a building that isn't from the exporter.
private let fixture = """
{
  "schema": "building_briefs.v1",
  "generated_at": "2026-11-14T12:00:00Z",
  "proposals": [{"id": "prop_1", "place": "Second floor landing"}],
  "buildings": [
    {
      "id": "mp:FIXTURE1",
      "name": "Fixture Tower",
      "address": "1 Test Plaza, Houston, TX",
      "geofence": {"lat": 29.7600, "lon": -95.3700, "radius_m": 60},
      "plan_status": "verified",
      "layers": ["matterport", "vexcel", "costar"],
      "proposals": [{"id": "prop_2", "place": "Loading dock"}],
      "aeds": [
        {"id": "aed_1", "place": "Lobby, wall cabinet left of the elevators", "floor": "Ground floor",
         "scan_date": "2024-05", "confirmed_at": "2026-11-14"},
        {"id": "aed_2", "place": "Gym, by the water fountain", "floor": "Level 3",
         "scan_date": "", "confirmed_at": "2026-11-14"},
        {"id": "aed_3", "place": "Mail room", "floor": "Ground floor",
         "scan_date": "2024-05", "confirmed_at": ""},
        {"id": "aed_4", "place": "", "floor": "Level 2",
         "scan_date": "2024-05", "confirmed_at": "2026-11-14"},
        {"id": "aed_5", "place": "Garage entrance", "floor": "P1",
         "scan_date": "2024-05", "confirmed_at": "2026-11-14"}
      ],
      "ems_entrance": {"text": "West side, main lobby doors", "checked_from": ["scan", "aerial"], "status": "two_layers_agree"}
    },
    {
      "id": "mp:FIXTURE2",
      "name": "Draft Annex",
      "address": "3 Test Plaza, Houston, TX",
      "geofence": {"lat": 29.7700, "lon": -95.3700, "radius_m": 60},
      "plan_status": "draft",
      "aeds": [{"id": "aed_1", "place": "Front desk", "floor": "Ground floor", "scan_date": "2024-05", "confirmed_at": "2026-11-14"}]
    },
    {
      "id": "mp:FIXTURE3",
      "name": "Fixture Hall",
      "address": "",
      "geofence": {"lat": 29.7800, "lon": -95.3700, "radius_m": 40},
      "plan_status": "verified",
      "aeds": [],
      "ems_entrance": {"text": "North loading door", "checked_from": ["aerial"], "status": "one_layer"}
    }
  ]
}
"""

private func building(_ id: String, lat: Double, lon: Double, radius: Double = 60) -> BuildingBrief {
    BuildingBrief(
        id: id, name: id, address: "",
        geofence: .init(lat: lat, lon: lon, radiusM: radius),
        planStatus: BuildingBrief.verified
    )
}

/// About 111.2 km to a degree of latitude, so this is metres north of `lat`.
private func north(of lat: Double, metres: Double) -> Double { lat + metres / 111_195 }

@MainActor
@Suite struct BuildingBriefTests {
    let usable = BuildingBrief.usable(Data(fixture.utf8))

    // MARK: - The file

    @Test func theBundledFileDecodes() throws {
        let url = try #require(Bundle.main.url(forResource: BuildingBriefStore.resource, withExtension: "json"))
        let file = try BuildingBrief.decode(Data(contentsOf: url))
        #expect(file.schema == BuildingBriefFile.schema)
        // Whatever the exporter wrote, only approved buildings get through.
        #expect(BuildingBrief.usable(try Data(contentsOf: url)).allSatisfy { $0.planStatus == BuildingBrief.verified })
    }

    @Test func onlyVerifiedBuildingsAreKept() {
        #expect(usable.map(\.id) == ["mp:FIXTURE1", "mp:FIXTURE3"])
    }

    @Test func undatedUnconfirmedAndPlacelessAEDsAreDropped() throws {
        let tower = try #require(usable.first)
        #expect(tower.aeds.map(\.id) == ["aed_1", "aed_5"])
        #expect(tower.aeds[0].place == "Lobby, wall cabinet left of the elevators")
        #expect(tower.aeds[0].floor == "Ground floor")
    }

    @Test func aStrayProposalsKeyIsIgnored() throws {
        let file = try BuildingBrief.decode(Data(fixture.utf8))
        #expect(file.buildings.count == 3)
        let lines = usable.flatMap(everyLine)
        #expect(!lines.contains { $0.contains("Second floor landing") || $0.contains("Loading dock") })
    }

    @Test func anAEDThatSaysItIsProposedIsNotAnAED() {
        let aed = BuildingBrief.AED(id: "aed_9", place: "Proposed: by the stairs", floor: "", scanDate: "2024-05", confirmedAt: "2026-11-14")
        #expect(!aed.isUsable)
        let byID = BuildingBrief.AED(id: "proposal_1", place: "By the stairs", floor: "", scanDate: "2024-05", confirmedAt: "2026-11-14")
        #expect(!byID.isUsable)
    }

    @Test func anotherSchemaOrGarbageGivesNothing() {
        #expect(BuildingBrief.usable(Data(fixture.replacingOccurrences(of: "building_briefs.v1", with: "building_briefs.v2").utf8)).isEmpty)
        #expect(BuildingBrief.usable(Data("not json".utf8)).isEmpty)
        #expect(BuildingBrief.usable(Data()).isEmpty)
    }

    @Test func oneBrokenBuildingCostsOnlyThatBuilding() {
        let broken = fixture.replacingOccurrences(of: "\"name\": \"Fixture Hall\",", with: "")
        #expect(BuildingBrief.usable(Data(broken.utf8)).map(\.id) == ["mp:FIXTURE1"])
    }

    // MARK: - Wording

    @Test func theLinesReadAsPinned() throws {
        let tower = try #require(usable.first)
        #expect(BuildingWording.match(tower)
            == "Looks like Fixture Tower, 1 Test Plaza, Houston, TX. From a building survey, matched by approximate location. Check it's where you are.")
        #expect(BuildingWording.aeds(tower).first
            == "AED seen in a building scan dated May 2024: Lobby, wall cabinet left of the elevators, Ground floor. It may have moved. Check it's there.")
        #expect(BuildingWording.entrance(tower)
            == "Suggested EMS entrance: West side, main lobby doors. AI-assisted from the scan and aerial photos, approved by a person, not checked on site.")

        let hall = try #require(usable.last)
        #expect(BuildingWording.aeds(hall) == ["No AED was seen in this building's scan. Ask people nearby."])
        #expect(BuildingWording.entrance(hall)
            == "Suggested EMS entrance: North loading door. AI-assisted from the aerial photos only, approved by a person, not checked on site.")
        var scanOnly = hall
        scanOnly.emsEntrance?.checkedFrom = ["scan"]
        #expect(BuildingWording.entrance(scanOnly)?.contains("AI-assisted from the scan only,") == true)
        scanOnly.emsEntrance?.checkedFrom = []
        #expect(BuildingWording.entrance(scanOnly) == nil)
    }

    @Test func scanDatesPrintAsMonthAndYear() {
        #expect(BuildingWording.monthYear("2024-05") == "May 2024")
        #expect(BuildingWording.monthYear("2023-12-01") == "Dec 2023")
        #expect(BuildingWording.monthYear("2024-13") == nil)
        #expect(BuildingWording.monthYear("May 2024") == nil)
        #expect(BuildingWording.monthYear("") == nil)
    }

    @Test func nothingIsSpokenUntilConfirmed() throws {
        let tower = try #require(usable.first)
        #expect(BuildingWording.spoken(tower, confirmed: false) == nil)
        var oneAED = tower
        oneAED.aeds = [tower.aeds[0]]
        #expect(BuildingWording.spoken(oneAED, confirmed: true)
            == "This is a simulation. The caller confirms they are in Fixture Tower. A building survey suggests EMS use West side, main lobby doors. It was not checked on site. An AED was seen in a scan of this building: Lobby, wall cabinet left of the elevators.")
        #expect(BuildingWording.spoken(tower, confirmed: true)?.hasSuffix(
            "AEDs were seen in a scan of this building: Lobby, wall cabinet left of the elevators; Garage entrance."
        ) == true)
        let hall = try #require(usable.last)
        #expect(BuildingWording.spoken(hall, confirmed: true)?.hasSuffix("No AED was seen in this building's scan.") == true)
    }

    @Test func theBannedWordsNeverAppear() throws {
        let walks = try [60, 100, 180].map { try tower(walk: $0) }
        let lines = BuildingWording.fixedStrings + (usable + walks).flatMap(everyLine)
        #expect(!lines.isEmpty)
        for line in lines {
            let lower = line.lowercased()
            #expect(!lower.contains("nearest"), "\(line)")
            #expect(!lower.contains("proposed"), "\(line)")
            #expect(!lower.contains("proposal"), "\(line)")
        }
    }

    // MARK: - Near or far

    private static let lobby = "Lobby, wall cabinet left of the elevators, Ground floor"
    private static let seen = "Seen in a building scan dated May 2024. It may have moved."

    private func tower(walk: Int?) throws -> BuildingBrief {
        var tower = try #require(usable.first)
        tower.aeds = [tower.aeds[0]]
        tower.aeds[0].typicalWalkM = walk
        return tower
    }

    @Test func aFileWithoutTheWalkStillDecodes() throws {
        #expect(!fixture.contains("typical_walk_m"))
        let tower = try #require(usable.first)
        #expect(tower.aeds.map(\.typicalWalkM) == [nil, nil])
    }

    @Test func theWalkDecodesAsGivenAndABadOneCostsOnlyTheAdvice() throws {
        func walk(_ json: String) throws -> Int? {
            let file = fixture.replacingOccurrences(of: #""id": "aed_1","#, with: #""id": "aed_1", "typical_walk_m": \#(json),"#)
            return try #require(BuildingBrief.usable(Data(file.utf8)).first?.aeds.first { $0.id == "aed_1" }).typicalWalkM
        }
        #expect(try walk("60") == 60)
        #expect(try walk("180") == 180)
        #expect(try walk("null") == nil)
        #expect(try walk(#""far""#) == nil)
        #expect(try walk("-10") == nil)
    }

    @Test func sixtyMetresIsNear() throws {
        let tower = try tower(walk: 60)
        #expect(BuildingWording.aeds(tower) == [
            "AED about 60 m away: \(Self.lobby). Send someone to get it. If you're alone, get it and come straight back. \(Self.seen)",
        ])
        #expect(BuildingWording.spoken(tower, confirmed: true)?.hasSuffix(
            "An AED was seen in a scan of this building, about 60 m away: Lobby, wall cabinet left of the elevators. Send someone to get it. If you're alone, get it and come straight back."
        ) == true)
    }

    @Test func aHundredMetresIsStillNear() throws {
        let tower = try tower(walk: 100)
        #expect(BuildingWording.aeds(tower).first?.hasPrefix("AED about 100 m away: \(Self.lobby). Send someone to get it.") == true)
        #expect(BuildingWording.spoken(tower, confirmed: true)?.contains("about 100 m away") == true)
        #expect(tower.aeds[0].reach == .near(100))
    }

    @Test func aHundredAndEightyMetresIsFar() throws {
        let tower = try tower(walk: 180)
        #expect(tower.aeds[0].reach == .far(180))
        #expect(BuildingWording.aeds(tower) == [
            "The AED seen in this building is a long walk away (about 180 m): \(Self.lobby). Don't leave the person to get it. Keep pushing. If someone is with you, send them. \(Self.seen)",
        ])
        let spoken = try #require(BuildingWording.spoken(tower, confirmed: true))
        #expect(spoken.hasSuffix(
            "The AED seen in a scan of this building is a long walk away, about 180 m: Lobby, wall cabinet left of the elevators. Don't leave the person to get it. Keep pushing. If someone is with you, send them."
        ))
        #expect(!spoken.contains("get it and come straight back"))
    }

    @Test func noWalkGivesTodaysLineWithNoAdvice() throws {
        let tower = try tower(walk: nil)
        #expect(tower.aeds[0].reach == nil)
        #expect(BuildingWording.aeds(tower) == [
            "AED seen in a building scan dated May 2024: \(Self.lobby). It may have moved. Check it's there.",
        ])
        let spoken = try #require(BuildingWording.spoken(tower, confirmed: true))
        #expect(spoken.hasSuffix("An AED was seen in a scan of this building: Lobby, wall cabinet left of the elevators."))
        #expect(!spoken.contains("Send someone") && !spoken.contains("Keep pushing"))
    }

    @Test func nearOrFarIsStillSpokenOnlyAfterConfirmation() throws {
        #expect(BuildingWording.spoken(try tower(walk: 60), confirmed: false) == nil)
        #expect(BuildingWording.spoken(try tower(walk: 180), confirmed: false) == nil)
    }

    @Test func theShortestKnownWalkDecidesWhatIsSpoken() throws {
        var tower = try #require(usable.first)
        tower.aeds[0].typicalWalkM = 180
        tower.aeds[1].typicalWalkM = 70
        let spoken = try #require(BuildingWording.spoken(tower, confirmed: true))
        #expect(spoken.contains("about 70 m away: Garage entrance."))
        #expect(!spoken.contains("Keep pushing"))
        // Each line on the sheet keeps its own advice.
        #expect(BuildingWording.aeds(tower).map { $0.contains("long walk") } == [true, false])
    }

    @Test func theHandoffRowCarriesTheWalk() throws {
        let rows = BuildingHandoffRows.rows(try tower(walk: 60))
        #expect(rows[1].meta == "about 60 m walk, scan May 2024, may have moved")
        #expect(BuildingHandoffRows.rows(try tower(walk: nil))[1].meta == "scan May 2024, may have moved")
    }

    // MARK: - Confirmation

    @Test func aConfirmationCountsOnlyForItsOwnRescue() {
        let store = BuildingBriefStore(buildings: usable, stagedID: "mp:FIXTURE1")
        let runA: TimeInterval = 1000
        let runB: TimeInterval = 1500
        #expect(!store.isConfirmed(run: runA))
        store.confirm(run: runA)
        #expect(store.isConfirmed(run: runA))
        #expect(!store.isConfirmed(run: runB))
        #expect(store.confirmed(run: runA)?.id == "mp:FIXTURE1")
        #expect(store.confirmed(run: runB) == nil)
    }

    @Test func choosingAnotherBuildingNeedsItsOwnConfirmation() {
        let store = BuildingBriefStore(buildings: usable, stagedID: "mp:FIXTURE1")
        store.confirm(run: 1000)
        store.pick("mp:FIXTURE3")
        #expect(store.selected?.id == "mp:FIXTURE3")
        #expect(store.isPickedByHand)
        #expect(!store.isConfirmed(run: 1000))
        store.pick(nil)
        #expect(store.selected?.id == "mp:FIXTURE1")
        #expect(!store.isConfirmed(run: 1000))
    }

    @Test func aHandPickBeatsStagingWhichBeatsLocation() {
        let locator = BuildingLocator()
        let store = BuildingBriefStore(buildings: usable, locator: locator)
        #expect(store.selected == nil)
        locator.received(CLLocation(
            coordinate: .init(latitude: 29.7800, longitude: -95.3700), altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: Date()
        ))
        #expect(store.selected?.id == "mp:FIXTURE3")
        #expect(!store.isPickedByHand)

        let staged = BuildingBriefStore(buildings: usable, stagedID: "mp:FIXTURE1", locator: locator)
        #expect(staged.selected?.id == "mp:FIXTURE1")
        staged.pick("mp:FIXTURE3")
        #expect(staged.selected?.id == "mp:FIXTURE3")

        // A building that isn't usable can't be staged or picked into view.
        let draft = BuildingBriefStore(buildings: usable, stagedID: "mp:FIXTURE2")
        draft.pick("mp:FIXTURE2")
        #expect(draft.selected == nil)
    }

    @Test func anOldCachedFixIsIgnored() {
        let locator = BuildingLocator()
        locator.received(CLLocation(
            coordinate: .init(latitude: 29.76, longitude: -95.37), altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: Date(timeIntervalSinceNow: -3600)
        ))
        #expect(locator.fix == nil)
        locator.received(CLLocation(
            coordinate: .init(latitude: 29.76, longitude: -95.37), altitude: 0,
            horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date()
        ))
        #expect(locator.fix == nil)
    }

    // MARK: - Geofence

    @Test func aFixInsideTheFenceMatches() {
        let tower = building("tower", lat: 29.76, lon: -95.37)
        let fix = BuildingLocator.Fix(latitude: north(of: 29.76, metres: 40), longitude: -95.37, accuracy: 10)
        #expect(BuildingLocator.match(fix, in: [tower])?.id == "tower")
    }

    @Test func aFixOutsideTheFenceDoesNot() {
        let tower = building("tower", lat: 29.76, lon: -95.37)
        let fix = BuildingLocator.Fix(latitude: north(of: 29.76, metres: 200), longitude: -95.37, accuracy: 10)
        #expect(BuildingLocator.match(fix, in: [tower]) == nil)
        #expect(BuildingLocator.match(nil, in: [tower]) == nil)
    }

    @Test func accuracyWidensTheFenceByAtMostFiftyMetres() {
        let tower = building("tower", lat: 29.76, lon: -95.37)
        let lat = north(of: 29.76, metres: 100)
        // 60 + 45 reaches 100 m out.
        #expect(BuildingLocator.match(.init(latitude: lat, longitude: -95.37, accuracy: 45), in: [tower]) != nil)
        // 60 + 30 doesn't.
        #expect(BuildingLocator.match(.init(latitude: lat, longitude: -95.37, accuracy: 30), in: [tower]) == nil)
        // 90 m of doubt still widens it by only 50, so 115 m out is outside.
        let further = north(of: 29.76, metres: 115)
        #expect(BuildingLocator.match(.init(latitude: further, longitude: -95.37, accuracy: 90), in: [tower]) == nil)
    }

    @Test func aPoorFixMatchesNothing() {
        let tower = building("tower", lat: 29.76, lon: -95.37)
        #expect(BuildingLocator.match(.init(latitude: 29.76, longitude: -95.37, accuracy: 101), in: [tower]) == nil)
        #expect(BuildingLocator.match(.init(latitude: 29.76, longitude: -95.37, accuracy: 100), in: [tower]) != nil)
        #expect(BuildingLocator.match(.init(latitude: 29.76, longitude: -95.37, accuracy: -1), in: [tower]) == nil)
    }

    @Test func twoOverlappingBuildingsMatchNeither() {
        let east = building("east", lat: 29.76, lon: -95.37)
        let west = building("west", lat: north(of: 29.76, metres: 50), lon: -95.37)
        let between = BuildingLocator.Fix(latitude: north(of: 29.76, metres: 25), longitude: -95.37, accuracy: 5)
        #expect(BuildingLocator.match(between, in: [east, west]) == nil)
        #expect(BuildingLocator.match(between, in: [east])?.id == "east")
    }

    @Test func haversineIsRoughlyRight() {
        // One degree of latitude is about 111.2 km anywhere.
        #expect(abs(BuildingLocator.distance(29, -95, 30, -95) - 111_195) < 50)
        #expect(BuildingLocator.distance(29.76, -95.37, 29.76, -95.37) == 0)
    }

    // MARK: - The section

    @Test func anEmptyListHidesTheSection() {
        #expect(!BuildingBriefStore(buildings: []).showsSection)
        let onlyDrafts = fixture.replacingOccurrences(of: "\"verified\"", with: "\"draft\"")
        #expect(!BuildingBriefStore(buildings: BuildingBrief.usable(Data(onlyDrafts.utf8))).showsSection)
        let empty = #"{"schema":"building_briefs.v1","generated_at":"","buildings":[]}"#
        #expect(!BuildingBriefStore(buildings: BuildingBrief.usable(Data(empty.utf8))).showsSection)
        #expect(BuildingBriefStore(buildings: usable).showsSection)
    }

    @Test func theHandoffRowsComeOnlyAfterConfirmation() throws {
        let store = BuildingBriefStore(buildings: usable, stagedID: "mp:FIXTURE1")
        #expect(store.confirmed(run: 1000) == nil)
        store.confirm(run: 1000)
        let tower = try #require(store.confirmed(run: 1000))
        let rows = BuildingHandoffRows.rows(tower)
        #expect(rows.map(\.label) == ["Building", "AED seen in scan", "AED seen in scan", "Suggested EMS entrance"])
        #expect(rows.last?.tag == "AI-assisted")
        #expect(rows.last?.caution == true)
    }

    /// Everything the section, the spoken line and the handoff rows would say for one building.
    private func everyLine(_ building: BuildingBrief) -> [String] {
        var lines = [BuildingWording.match(building), BuildingWording.nameAndAddress(building)]
        lines += BuildingWording.aeds(building)
        lines += [BuildingWording.entrance(building), BuildingWording.spoken(building, confirmed: true)].compactMap(\.self)
        lines += BuildingHandoffRows.rows(building).flatMap { [$0.label, $0.value, $0.meta, $0.tag].compactMap(\.self) }
        return lines
    }
}
