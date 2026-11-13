import Foundation
import Testing
@testable import RescueCore

@Suite struct AwakeContractTests {
    private let kinds: Set<String> = [
        "unresponsive", "not_breathing", "abnormal_breathing", "dispatcher_speaking", "chest_pain",
        "other_heart_signs", "limb_injury", "limb_discolored", "heavy_bleeding", "neck_back_injury",
        "choking", "other_concern", "aspirin_unsafe",
    ]

    private func tools(_ file: String) throws -> [[String: Any]] {
        let url = repoRoot().appendingPathComponent("contracts/\(file)")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["function_declarations"] as? [[String: Any]])
    }

    private func kindSchema() throws -> [String: Any] {
        let tool = try #require(try tools("tools.awake.v1.json").first { $0["name"] as? String == "report_finding" })
        let parameters = try #require(tool["parameters"] as? [String: Any])
        let properties = try #require(parameters["properties"] as? [String: [String: Any]])
        return try #require(properties["kind"])
    }

    @Test func kindIsExactlyTheAwakeList() throws {
        let declared = try #require(try kindSchema()["enum"] as? [String])
        #expect(declared.count == kinds.count)
        #expect(Set(declared) == kinds)
        #expect(Set(declared).isSubset(of: Set(Finding.allCases.map(\.rawValue))))
        #expect(Set(declared).isDisjoint(with: ["responsive", "patient_moving", "breathing_normally", "ems_arrived", "aed_prompting"]))
        for finding in Finding.allCases where kinds.contains(finding.rawValue) {
            #expect(!finding.wouldLowerUrgency, "\(finding)")
        }
    }

    @Test func eachKindHasOneLineSayingWhatItMeans() throws {
        let description = try #require(try kindSchema()["description"] as? String)
        let lines = description.split(separator: "\n")
        #expect(lines.count == kinds.count)
        #expect(Set(lines.compactMap { $0.split(separator: ":").first.map(String.init) }) == kinds)
    }

    /// Either one reported on someone talking would start the road to CPR with no human input.
    @Test(arguments: ["not_breathing", "abnormal_breathing"])
    func aBreathingFindingSaysATalkingPersonIsNotIt(kind: String) throws {
        let description = try #require(try kindSchema()["description"] as? String)
        let line = try #require(description.split(separator: "\n").first { $0.hasPrefix("\(kind):") })
        #expect(line.contains("A person who is talking is not this."))
    }

    private func line(of kind: String) throws -> String {
        let description = try #require(try kindSchema()["description"] as? String)
        return try #require(description.split(separator: "\n").first { $0.hasPrefix("\(kind):") }.map(String.init))
    }

    /// A mis-tapped Yes leaves the awake session listening to someone in arrest, and on main the
    /// arrest session would have taken gasping straight to CPR.
    @Test func gaspingInSomeoneNotTalkingIsAbnormalBreathingWhateverTheTapSaid() throws {
        let line = try line(of: "abnormal_breathing")
        for sign in ["gasping", "snoring", "only occasional breaths", "not talking", "even if they were awake before"] {
            #expect(line.contains(sign), "missing: \(sign)")
        }
    }

    /// The heart attack flow ends in an aspirin dose, which has no place for breathlessness alone.
    @Test func breathingTroubleInSomeoneTalkingIsNotAHeartSign() throws {
        #expect(!(try line(of: "other_heart_signs")).contains("breath"))
        #expect(try line(of: "other_concern").contains("trouble breathing in someone still talking"))
    }

    @Test func everythingElseMatchesTheArrestContract() throws {
        let arrest = try tools("tools.v1.json")
        let awake = try tools("tools.awake.v1.json")
        #expect(awake.compactMap { $0["name"] as? String } == arrest.compactMap { $0["name"] as? String })

        for (old, new) in zip(arrest, awake) where old["name"] as? String != "report_finding" {
            #expect((old as NSDictionary).isEqual(to: new), "\(old["name"] ?? "?")")
        }

        func withoutKind(_ tools: [[String: Any]]) throws -> [String: Any] {
            var tool = try #require(tools.first { $0["name"] as? String == "report_finding" })
            var parameters = try #require(tool["parameters"] as? [String: Any])
            var properties = try #require(parameters["properties"] as? [String: Any])
            properties["kind"] = nil
            parameters["properties"] = properties
            tool["parameters"] = parameters
            return tool
        }
        let oldReport = try withoutKind(arrest)
        let newReport = try withoutKind(awake)
        #expect((oldReport as NSDictionary).isEqual(to: newReport))
    }
}
