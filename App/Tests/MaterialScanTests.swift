import Foundation
@testable import HealthAISim
@testable import RescueCore
import RescueLive
import RescueVision
import Synchronization
import Testing

/// Towel, pillow and gloves are found on frozen frames for the limb steps' callouts, the way the AED
/// always has been for its arrow: started by the app, asked again until seen, never by the model.
@MainActor
@Suite struct MaterialScanTests {
    private let everything: Set<RescueCore.Material> = [.towel, .pillow, .gloves]

    private func begun(canLocate: Bool = true, camera: Bool = true) throws -> Fixture {
        let fixture = try Fixture(canLocate: canLocate, arSupported: camera, cameraAllowed: camera, bundle: try mergedBundle())
        fixture.coordinator.beginRescue()
        fixture.coordinator.perform(.yes)
        return fixture
    }

    private func toLimbStart(_ fixture: Fixture) {
        fixture.coordinator.perform(.triageLimb)
        #expect(fixture.coordinator.state.stateID == "limb_start")
    }

    /// The scan starts at the flow's first step, so a locate taking seconds is in by limb_splint.
    @Test func theFlowsFirstStepLooksForEverythingTheFlowPointsAt() throws {
        let fixture = try begun()
        #expect(fixture.vision.locateRequests.isEmpty, "triage points at nothing")
        toLimbStart(fixture)
        #expect(fixture.vision.locateRequests == [everything])
        #expect(fixture.gate.locateOpen)
        #expect(!fixture.gate.framesOpen, "nothing streams to the model")
        #expect(fixture.vision.locateCount == 0, "the AED isn't one of them")
    }

    @Test func noKeyOrNoCameraLooksForNothing() throws {
        for fixture in [try begun(canLocate: false), try begun(camera: false)] {
            toLimbStart(fixture)
            fixture.run(seconds: 4)
            #expect(fixture.vision.locateRequests.isEmpty)
        }
    }

    /// One in flight answers for itself. A callout needs two sightings, so one isn't enough.
    @Test func eachMaterialIsAskedAgainUntilSeenTwice() throws {
        let fixture = try begun()
        toLimbStart(fixture)
        for material in everything { fixture.vision.setLocateStatus(.locating, for: material) }
        fixture.run(seconds: 2.2)
        #expect(fixture.vision.locateRequests.count == 1, "all still on their way")

        fixture.vision.setLocateStatus(.located, for: .towel, sightings: 1)
        fixture.vision.setLocateStatus(.notFound, for: .pillow)
        fixture.vision.setLocateStatus(.located, for: .gloves, sightings: 2)
        fixture.run(seconds: 2.2)
        #expect(fixture.vision.locateRequests.last == [.towel, .pillow])

        fixture.vision.setLocateStatus(.located, for: .towel, sightings: 2)
        fixture.vision.setLocateStatus(.located, for: .pillow, sightings: 2)
        let asked = fixture.vision.locateRequests.count
        fixture.run(seconds: 2.2)
        #expect(fixture.vision.locateRequests.count == asked, "seen often enough")
    }

    @Test func aStepsCuesAreWhatItPointsAt() throws {
        let fixture = try begun()
        toLimbStart(fixture)
        #expect(fixture.coordinator.cues.isEmpty)
        fixture.coordinator.perform(.done)
        fixture.coordinator.perform(.no)
        #expect(fixture.coordinator.state.stateID == "limb_splint")
        #expect(fixture.coordinator.cues.compactMap(\.callout) == ["Pad under · Towel", "Pad under · Pillow"])
        #expect(fixture.coordinator.cues.allSatisfy { $0.body == .injuredLimb })

        fixture.coordinator.perform(.done)
        #expect(fixture.coordinator.state.stateID == "limb_wait")
        #expect(fixture.coordinator.cues.compactMap(\.material) == [.towel, .pillow], "the support carries into the wait")
        fixture.coordinator.perform(.patientUnresponsive)
        #expect(fixture.coordinator.cues.isEmpty, "a step with none clears them")
    }

    /// The command's own words light up with the marks the step's cues draw.
    @Test func theCommandLightsUpTheCuesWords() throws {
        let fixture = try begun()
        toLimbStart(fixture)
        [HumanAction.done, .no].forEach(fixture.coordinator.perform)
        let command = fixture.coordinator.deckCommand
        let terms = fixture.coordinator.commandTerms
        #expect(terms.item.contains("towel") && terms.item.contains("pillow"))
        #expect(terms.body.contains("limb"))
        // The line the towel and pillow marks belong to leads, so the word said big is the one lit up.
        #expect(command == fixture.coordinator.engine.bundle.text(forPhrase: "limb_support"))
        #expect(fixture.coordinator.deckDetail == fixture.coordinator.engine.bundle.text(forPhrase: "limb_wound"))
        #expect(fixture.coordinator.instruction == fixture.coordinator.engine.bundle.text(forPhrase: "limb_wound"), "instruction stays as pinned")
        let item = try #require(CommandEmphasis.firstWholeWord(in: command, from: terms.item))
        #expect(command[item].lowercased() == "towel", "\(command)")
        #expect(String(CommandEmphasis.attributed(command, terms: terms).characters) == command, "never a word changed")
    }

    @Test func nothingIsLookedForOutsideTheLimbFlow() throws {
        let fixture = try begun()
        [HumanAction.triageChest, .done, .yes, .scan].forEach(fixture.coordinator.perform)
        #expect(fixture.coordinator.state.stateID == "chest_scan")
        fixture.run(seconds: 4)
        #expect(fixture.vision.locateRequests.isEmpty)
        #expect(fixture.coordinator.materialsToScan(at: fixture.clock.now).isEmpty)
    }

    /// A call closes the permission like the uplink, so nothing leaves the phone while someone's on it.
    @Test func aCallStopsTheScan() throws {
        let fixture = try begun()
        toLimbStart(fixture)
        fixture.coordinator.dispatch(.callChanged(active: true))
        #expect(fixture.coordinator.materialsToScan(at: fixture.clock.now).isEmpty)
        #expect(!fixture.gate.locateOpen)
        let asked = fixture.vision.locateRequests.count
        fixture.run(seconds: 2.2)
        #expect(fixture.vision.locateRequests.count == asked)
    }
}

/// The app's bridge to the cloud locator checks the gates again at the last moment.
@Suite struct ObjectLocatorBridgeTests {
    private final class Calls: Sendable {
        let count = Mutex(0)
    }

    private func bridge(_ calls: Calls, gate: UplinkGate) -> GeminiObjectLocator {
        let http: HTTPClient = { request in
            calls.count.withLock { $0 += 1 }
            let boxes = #"{\"boxes\":[{\"label\":\"towel\",\"box_2d\":[100,100,500,500]},{\"label\":\"towel\",\"box_2d\":[600,600,900,900]}]}"#
            let body = #"{"candidates":[{"content":{"parts":[{"text":"\#(boxes)"}]}}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return GeminiObjectLocator(locator: GeminiLocator(apiKey: APIKey("test"), http: http), gate: gate)
    }

    @Test func materialsGoOnlyThroughTheLocateGate() async {
        let calls = Calls()
        let gate = UplinkGate()
        let locator = bridge(calls, gate: gate)
        #expect(await locator.locate(jpeg: Data([0xFF, 0xD8]), materials: [.towel, .pillow]).isEmpty, "closed until a policy opens it")
        #expect(calls.count.withLock { $0 } == 0)

        var policy = RuntimePolicy(modelSpeechOpen: false, micUplink: true, frameUplink: false, audioMode: .full)
        policy.frameLocate = true
        gate.setPolicy(policy)
        let boxes = await locator.locate(jpeg: Data([0xFF, 0xD8]), materials: [.towel, .pillow])
        #expect(calls.count.withLock { $0 } == 1, "one request for both")
        #expect(boxes[.towel] == NormalizedBox(minX: 0.1, minY: 0.1, maxX: 0.5, maxY: 0.5), "the first, most prominent, box")
        #expect(boxes[.pillow] == nil)

        #expect(await locator.locate(jpeg: Data([0xFF, 0xD8]), materials: [.aed]).isEmpty, "the AED still needs the uplink")
        #expect(calls.count.withLock { $0 } == 1)
    }

    /// The arrest path opens the uplink for the AED's scan, and a towel still waiting from a limb step
    /// mustn't go out on it.
    @Test func theUplinkAloneSendsNoMaterial() async {
        let calls = Calls()
        let gate = UplinkGate()
        let locator = bridge(calls, gate: gate)
        gate.setPolicy(RuntimePolicy(modelSpeechOpen: true, micUplink: true, frameUplink: true, audioMode: .full))
        #expect(gate.locateOpen && !gate.materialsOpen)
        #expect(await locator.locate(jpeg: Data([0xFF, 0xD8]), materials: [.towel, .pillow, .gloves]).isEmpty)
        #expect(calls.count.withLock { $0 } == 0, "the image never left the phone")
    }
}
