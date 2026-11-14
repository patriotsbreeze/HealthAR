import Foundation
@testable import HealthAISim
import simd
import Testing

/// Made up for these tests. A demo AED with a route (flagged staged, which is never shown), one with a longer route,
/// and an AED whose route the guide can't use.
private let routed = """
{
  "schema": "building_briefs.v1",
  "generated_at": "2026-11-14T20:00:00Z",
  "buildings": [{
    "id": "mp:ROUTED",
    "name": "Fixture Hall",
    "address": "2 Test Plaza",
    "geofence": {"lat": 40.0, "lon": -74.0, "radius_m": 60},
    "plan_status": "verified",
    "aeds": [
      {"id": "staged_1", "place": "AED by the stairs", "floor": "Floor 1", "scan_date": "2026-11",
       "confirmed_at": "2026-11-14", "typical_walk_m": 20, "staged": true,
       "route_from_entrance": {"anchor": "entrance", "anchor_text": "Front doors", "length_m": 24.9,
         "floor_change": false, "waypoints": [[0.0, 0.0], [0.0, 24.85]]}},
      {"id": "aed_1", "place": "Lobby cabinet", "floor": "Floor 2", "scan_date": "2024-05",
       "confirmed_at": "2026-11-14", "typical_walk_m": 180,
       "route_from_entrance": {"anchor": "entrance", "anchor_text": "Front doors", "length_m": 40,
         "floor_change": true, "waypoints": [[0, 0], [0, 10], [5, 10], [5, 35]]}},
      {"id": "aed_2", "place": "Gym", "floor": "Floor 3", "scan_date": "2024-05", "confirmed_at": "2026-11-14",
       "route_from_entrance": {"anchor": "lobby", "anchor_text": "Lobby", "waypoints": [[0, 0], [0, 5]]}},
      {"id": "aed_3", "place": "Library", "floor": "Floor 1", "scan_date": "2024-05", "confirmed_at": "2026-11-14",
       "route_from_entrance": {"anchor": "entrance", "anchor_text": "Front doors", "waypoints": [[0, 0], [1]]}}
    ]
  }]
}
"""

private func pose(yaw: Float = 0, pitch: Float = 0, at position: SIMD3<Float> = .zero) -> simd_float4x4 {
    var matrix = simd_float4x4(simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0]))
    matrix.columns.3 = SIMD4(position, 1)
    return matrix
}

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 1e-4 }
private func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool { simd_distance(a, b) < 1e-4 }
private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

@MainActor
@Suite struct AEDGuideTests {
    let building = BuildingBrief.usable(Data(routed.utf8)).first

    // MARK: - (right, forward) to the world

    @Test func theIdentityPoseFacesMinusZ() throws {
        let frame = try #require(EntranceFrame.calibrate(camera: matrix_identity_float4x4, floorY: nil))
        // No floor found, so 1.4 m under the camera.
        #expect(close(frame.origin, [0, -1.4, 0]))
        #expect(close(frame.forward, [0, 0, -1]))
        #expect(close(frame.right, [1, 0, 0]))
        #expect(close(frame.world([0, 24.85]), [0, -1.4, -24.85]))
        #expect(close(frame.world([2, 3]), [2, -1.4, -3]))
    }

    @Test func facingPlusXTheRightIsPlusZ() throws {
        let frame = try #require(EntranceFrame.calibrate(camera: pose(yaw: -.pi / 2, at: [3, 1.5, 2]), floorY: 0))
        #expect(close(frame.origin, [3, 0, 2]))
        #expect(close(frame.forward, [1, 0, 0]))
        #expect(close(frame.right, [0, 0, 1]))
        #expect(close(frame.world([1, 5]), [8, 0, 3]))
    }

    @Test func facingMinusZTiltedDownIsMadeLevel() throws {
        let frame = try #require(EntranceFrame.calibrate(camera: pose(pitch: -0.5, at: [-1, 1.6, 4]), floorY: 0.1))
        #expect(close(frame.origin, [-1, 0.1, 4]))
        #expect(close(frame.forward, [0, 0, -1]))
        #expect(close(frame.right, [1, 0, 0]))
        #expect(close(frame.world([-2, 10]), [-3, 0.1, -6]))
    }

    @Test func aPhoneHeldFlatCantSayWhichWayIsIn() {
        #expect(EntranceFrame.calibrate(camera: pose(pitch: -.pi / 2), floorY: 0) == nil)
        #expect(EntranceFrame.calibrate(camera: pose(pitch: .pi / 2), floorY: 0) == nil)
    }

    @Test func aWorldPointComesBackToItsWaypoint() throws {
        let frame = try #require(EntranceFrame.calibrate(camera: pose(yaw: 0.7, pitch: -0.2, at: [5, 1.5, -3]), floorY: 0))
        let waypoint = SIMD2<Double>(-2.5, 7)
        // Height doesn't count: a phone 1.2 m up is still at that waypoint.
        #expect(close(frame.local(frame.world(waypoint) + [0, 1.2, 0]), waypoint))
    }

    // MARK: - Distance and turns

    private let right: [SIMD2<Double>] = [[0, 0], [0, 10], [5, 10]]
    private let left: [SIMD2<Double>] = [[0, 0], [0, 10], [-5, 10]]

    @Test func remainingIsAlongWhatsLeftOfThePath() {
        #expect(close(AEDPath.progress(at: [0, 0], along: right).remaining, 15))
        #expect(close(AEDPath.progress(at: [0, 4], along: right).remaining, 11))
        // Half a metre off the path adds half a metre.
        #expect(close(AEDPath.progress(at: [0.5, 4], along: right).remaining, 11.5))
        #expect(close(AEDPath.progress(at: [3, 10], along: right).remaining, 2))
        #expect(close(AEDPath.progress(at: [5, 10], along: right).remaining, 0))
        // Behind the doorway, the step back to it counts too.
        #expect(close(AEDPath.progress(at: [0, -2], along: right).remaining, 17))
        #expect(close(AEDPath.length(right), 15))
    }

    @Test func theNextTurnIsLeftOrRightByTheCrossProduct() {
        let ahead = AEDPath.progress(at: [0, 4], along: right)
        #expect(ahead.turn == .right)
        #expect(close(ahead.toTurn, 6))
        #expect(AEDGuideWording.next(ahead, name: "AED") == "Turn right in 6 m")
        #expect(AEDPath.progress(at: [0, 4], along: left).turn == .left)
        #expect(AEDGuideWording.next(AEDPath.progress(at: [0, 9], along: left), name: "AED") == "Turn left now")
        // Past the corner there's no turn left to make.
        #expect(AEDPath.progress(at: [3, 10], along: right).turn == nil)
    }

    @Test func aGentleBendIsStraightOn() {
        let bend: [SIMD2<Double>] = [[0, 0], [0, 10], [1, 20]]
        #expect(AEDPath.turn(from: bend[0], at: bend[1], to: bend[2]) == nil)
        let progress = AEDPath.progress(at: [0, 2], along: bend)
        #expect(progress.turn == nil)
        #expect(AEDGuideWording.next(progress, name: "AED") == "Straight on to the AED")
    }

    @Test func theLaterOfTwoTurnsComesAfterTheFirst() {
        let zigzag: [SIMD2<Double>] = [[0, 0], [0, 5], [4, 5], [4, 12]]
        let start = AEDPath.progress(at: [0, 1], along: zigzag)
        #expect(start.turn == .right)
        #expect(close(start.toTurn, 4))
        let middle = AEDPath.progress(at: [2, 5], along: zigzag)
        #expect(middle.turn == .left)
        #expect(close(middle.toTurn, 2))
        #expect(close(middle.remaining, 9))
    }

    @Test func arrivingSaysLookAround() {
        let straight: [SIMD2<Double>] = [[0, 0], [0, 24.85]]
        #expect(AEDGuideWording.next(AEDPath.progress(at: [0, 24], along: straight), name: "AED")
            == "The AED should be right here. Look around.")
        #expect(AEDGuideWording.remaining(AEDPath.progress(at: [0, 0], along: straight)) == "About 25 m to go")
        #expect(AEDGuideWording.remaining(nil) == AEDGuideWording.finding)
    }

    @Test func thePretendWalkFollowsThePath() {
        #expect(close(AEDPath.point(at: 0, along: right), [0, 0]))
        #expect(close(AEDPath.point(at: 12, along: right), [2, 10]))
        #expect(close(AEDPath.point(at: 99, along: right), [5, 10]))
        #expect(close(AEDPath.point(at: -3, along: right), [0, 0]))
    }

    // MARK: - The file

    @Test func stagedAndRoutesDecode() throws {
        let building = try #require(building)
        #expect(building.aeds.map(\.id) == ["staged_1", "aed_1", "aed_2", "aed_3"])
        let prop = building.aeds[0]
        // Still read from the file, never shown.
        #expect(prop.staged)
        let route = try #require(prop.routeFromEntrance)
        #expect(route.anchorText == "Front doors")
        #expect(route.lengthM == 24.9)
        #expect(!route.floorChange)
        #expect(route.waypoints == [[0, 0], [0, 24.85]])
        #expect(building.aeds[1].routeFromEntrance?.floorChange == true)
        #expect(!building.aeds[1].staged)
    }

    @Test func aRouteTheGuideCantFollowCostsOnlyTheRoute() throws {
        let building = try #require(building)
        // Anchored somewhere other than the entrance, and a waypoint that isn't a pair.
        #expect(building.aeds[2].routeFromEntrance == nil)
        #expect(building.aeds[3].routeFromEntrance == nil)
        #expect(BuildingWording.aed(building.aeds[2]) != nil)
    }

    @Test func filesWithoutTheNewKeysStillDecode() throws {
        let old = #"{"schema":"building_briefs.v1","generated_at":"","buildings":[{"id":"mp:OLD","name":"Old","address":"","geofence":{"lat":0,"lon":0,"radius_m":60},"plan_status":"verified","aeds":[{"id":"aed_1","place":"Lobby","floor":"","scan_date":"2024-05","confirmed_at":"2026-11-14"}]}]}"#
        let aed = try #require(BuildingBrief.usable(Data(old.utf8)).first?.aeds.first)
        #expect(!aed.staged)
        #expect(aed.routeFromEntrance == nil)
        #expect(AEDGuideTarget(building: try #require(BuildingBrief.usable(Data(old.utf8)).first)) == nil)
    }

    @Test func everyAEDFromTheFileNeedsAScanDateStagedOrNot() {
        let undated = BuildingBrief.AED(id: "aed_9", place: "Lobby", floor: "", scanDate: "", confirmedAt: "2026-11-14")
        #expect(!undated.isUsable)
        var prop = undated
        prop.staged = true
        #expect(!prop.isUsable)
    }

    @Test func theGuideGoesToTheShortestRoute() throws {
        let building = try #require(building)
        let target = try #require(AEDGuideTarget(building: building))
        #expect(target.aed.id == "staged_1")
        #expect(target.name == "AED")
        #expect(target.pinText == "AED")
        var unstaged = building
        unstaged.aeds.removeFirst()
        let real = try #require(AEDGuideTarget(building: unstaged))
        #expect(real.aed.id == "aed_1")
        #expect(real.name == "AED")
        #expect(AEDGuideWording.stairs(real.aed) == "Take the stairs to Floor 2.")
    }

    // MARK: - A demo AED looks like any other

    @Test func aStagedAEDIsShownAsAPlainAED() throws {
        let building = try #require(building)
        let prop = building.aeds[0]
        #expect(BuildingWording.aed(prop)
            == "AED about 20 m away: AED by the stairs, Floor 1. Send someone to get it. If you're alone, get it and come straight back. Seen in a building scan dated Nov 2026. It may have moved.")
        let spoken = try #require(BuildingWording.spoken(building, confirmed: true))
        #expect(spoken.hasSuffix("An AED was seen in a scan of this building, about 20 m away: AED by the stairs. Send someone to get it. If you're alone, get it and come straight back."))
        let row = try #require(BuildingHandoffRows.rows(building).first { $0.value.hasPrefix("AED by the stairs") })
        #expect(row.label == "AED seen in scan")
        #expect(row.tag == "survey")
        #expect(!row.caution)
        // Nothing anywhere says it's a prop or staged.
        var lines = building.aeds.compactMap(BuildingWording.aed) + [spoken] + BuildingWording.fixedStrings + AEDGuideWording.fixedStrings
        lines += BuildingHandoffRows.rows(building).flatMap { [$0.label, $0.value, $0.meta, $0.tag].compactMap(\.self) }
        for line in lines {
            #expect(!line.lowercased().contains("prop"), "\(line)")
            #expect(!line.lowercased().contains("staged"), "\(line)")
            #expect(!line.lowercased().contains("demo"), "\(line)")
        }
    }

    @Test func theGuideNeverSaysTheBannedWords() throws {
        let building = try #require(building)
        var lines = AEDGuideWording.fixedStrings + BuildingWording.fixedStrings
        lines += building.aeds.compactMap(BuildingWording.aed)
        lines += [BuildingWording.spoken(building, confirmed: true)].compactMap(\.self)
        lines += building.aeds.compactMap(\.routeFromEntrance).map { AEDGuideWording.calibrate($0) }
        for line in lines {
            #expect(!line.lowercased().contains("nearest"), "\(line)")
            #expect(!line.lowercased().contains("proposed"), "\(line)")
        }
    }

    // MARK: - The local file

    @Test func theLocalFileWinsByBuildingID() throws {
        let building = try #require(building)
        var newer = building
        newer.name = "Fixture Hall, local"
        let other = BuildingBrief(id: "mp:OTHER", name: "Other", address: "", geofence: .init(lat: 1, lon: 1, radiusM: 60), planStatus: BuildingBrief.verified)
        let merged = BuildingBriefStore.merged([building, other], local: [newer])
        #expect(merged.map(\.id) == ["mp:ROUTED", "mp:OTHER"])
        #expect(merged[0].name == "Fixture Hall, local")
        #expect(BuildingBriefStore.merged([], local: [newer]).map(\.name) == ["Fixture Hall, local"])
        #expect(BuildingBriefStore.merged([other], local: []).map(\.id) == ["mp:OTHER"])
    }

    /// Only where a local file was copied in before the build. It's git-ignored, so CI has none.
    @Test func aLocalFileInTheBundleDecodes() throws {
        guard let url = Bundle.main.url(forResource: BuildingBriefStore.localResource, withExtension: "json") else { return }
        let file = try BuildingBrief.decode(Data(contentsOf: url))
        #expect(file.schema == BuildingBriefFile.schema)
        #expect(!BuildingBrief.usable(try Data(contentsOf: url)).isEmpty)
    }
}

/// Marking an AED by hand: the walk becomes its route, and the guide counts it.
@MainActor
@Suite struct MarkedAEDTests {
    private func store() -> MarkedAEDStore {
        let defaults = UserDefaults(suiteName: "MarkedAEDTests.\(UUID().uuidString)")!
        return MarkedAEDStore(defaults: defaults)
    }

    private let building = BuildingBrief(
        id: "mp:MARK", name: "Fixture Hall", address: "",
        geofence: .init(lat: 0, lon: 0, radiusM: 60), planStatus: BuildingBrief.verified,
        aeds: [BuildingBrief.AED(
            id: "staged_1", place: "AED by the stairs", floor: "Floor 1", scanDate: "2026-11", confirmedAt: "2026-11-14",
            typicalWalkM: 30, staged: true,
            routeFromEntrance: .init(anchorText: "Front arch", waypoints: [[0, 0], [0, 30]])
        )]
    )

    @Test func aWalkIsSimplifiedToItsCorners() {
        // Straight 10 m with a little sway, a right turn, then 5 m.
        let walk: [SIMD2<Double>] = [[0, 0], [0.2, 2], [-0.1, 4], [0.1, 6], [0, 8], [0, 10], [2, 10.2], [5, 10]]
        let simple = AEDPath.simplify(walk, tolerance: AEDPath.markTolerance)
        #expect(simple == [[0, 0], [0, 10], [5, 10]])
        #expect(AEDPath.simplify([[0, 0], [1, 1]], tolerance: 1) == [[0, 0], [1, 1]])
    }

    @Test func aMarkBecomesAnAEDWithItsWalkAsTheRoute() throws {
        let marks = store()
        let mark = try #require(marks.mark(building: "mp:MARK", walk: [[0, 0], [0, 6], [0, 12], [4, 12]], anchorText: "Front arch"))
        #expect(mark.waypoints == [[0, 0], [0, 12], [4, 12]])
        let aed = mark.aed
        #expect(aed.markedByHand)
        #expect(!aed.isFromScan)
        #expect(aed.isUsable)
        #expect(aed.typicalWalkM == 20)
        #expect(aed.routeFromEntrance?.anchorText == "Front arch")
        #expect(BuildingWording.aed(aed)?.hasPrefix("AED marked by hand (simulation) about 20 m away: Where it was marked.") == true)
        #expect(BuildingHandoffRows.rows(marks.withMarks(building)).contains { $0.tag == "marked" && $0.label == BuildingWording.marked })
    }

    @Test func theGuideGoesToAMarkedAEDWhenItsTheShorterWalk() throws {
        let marks = store()
        marks.mark(building: "mp:MARK", walk: [[0, 0], [0, 8], [3, 8]], anchorText: "Front arch")
        let store = BuildingBriefStore(buildings: [building], stagedID: "mp:MARK", marks: marks)
        let selected = try #require(store.selected)
        #expect(selected.aeds.count == 2)
        let target = try #require(AEDGuideTarget(building: selected))
        #expect(target.aed.markedByHand)
        #expect(target.pinText == "AED marked\nby hand")
        // Cleared, the prop is the target again.
        marks.clear(building: "mp:MARK")
        #expect(AEDGuideTarget(building: try #require(store.selected))?.aed.id == "staged_1")
    }

    @Test func marksSurviveARestartAndStayWithTheirBuilding() throws {
        let defaults = UserDefaults(suiteName: "MarkedAEDTests.\(UUID().uuidString)")!
        MarkedAEDStore(defaults: defaults).mark(building: "mp:MARK", walk: [[0, 0], [0, 5]], anchorText: "Front arch")
        let reopened = MarkedAEDStore(defaults: defaults)
        #expect(reopened.count(for: "mp:MARK") == 1)
        #expect(reopened.count(for: "mp:OTHER") == 0)
    }

    @Test func aWalkTooShortIsNotAMark() {
        let marks = store()
        #expect(marks.mark(building: "mp:MARK", walk: [[0, 0], [0.3, 0.2]], anchorText: "Front arch") == nil)
        #expect(marks.mark(building: "mp:MARK", walk: [[0, 0]], anchorText: "Front arch") == nil)
        #expect(marks.count(for: "mp:MARK") == 0)
    }

    @Test func theMarkWordingAvoidsTheBannedWords() {
        let lines = AEDGuideWording.fixedStrings + BuildingWording.fixedStrings + [AEDGuideWording.marked(metres: 20)]
        for line in lines {
            #expect(!line.lowercased().contains("nearest"), "\(line)")
            #expect(!line.lowercased().contains("proposed"), "\(line)")
        }
    }
}
