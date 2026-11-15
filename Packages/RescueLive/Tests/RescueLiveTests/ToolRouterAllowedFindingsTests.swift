import Foundation
import RescueCore
import Testing
@testable import RescueLive

@Suite struct ToolRouterAllowedFindingsTests {
    private let newFindings = Finding.allCases.filter { !Finding.arrestCases.contains($0) }

    private func report(_ finding: Finding) -> RealtimeFunctionCall {
        RealtimeFunctionCall(id: "call-1", name: "report_finding", args: [
            "kind": .string(finding.rawValue), "source": "heard", "confidence": "high", "state_version": .number(1),
        ])
    }

    private func awakeContract() throws -> Data {
        try Data(contentsOf: repoRoot().appendingPathComponent("contracts/tools.awake.v1.json"))
    }

    /// What the awake contract declares, read from the shipped file.
    private func awakeFindings() throws -> Set<Finding> {
        let declarations = try LiveSetup.functionDeclarations(fromContract: try awakeContract())
        for declaration in declarations {
            guard case let .object(tool) = declaration, tool["name"] == "report_finding",
                  case let .object(parameters)? = tool["parameters"],
                  case let .object(properties)? = parameters["properties"],
                  case let .object(kind)? = properties["kind"],
                  case let .array(values)? = kind["enum"]
            else { continue }
            return Set(values.compactMap { value in
                guard case let .string(raw) = value else { return nil }
                return Finding(rawValue: raw)
            })
        }
        Issue.record("no report_finding in the contract")
        return []
    }

    @Test func awakeFindingsAreRefusedByDefault() {
        let router = ToolRouter(clock: { 500 })
        #expect(newFindings.count == 12)
        for finding in newFindings {
            let routed = router.route(report(finding))
            #expect(routed.proposal == nil, "\(finding)")
            #expect(routed.response?.status == .rejected, "\(finding)")
            #expect(routed.response?.reason == .unknownValue, "\(finding)")
        }
    }

    @Test func arrestFindingsStillRouteByDefault() {
        let router = ToolRouter(clock: { 500 })
        for finding in Finding.arrestCases {
            #expect(router.route(report(finding)).proposal?.action == .reportFinding(finding, source: .heard, confidence: .high))
        }
    }

    @Test func awakeFindingsRouteWhenTheSessionAllowsThem() throws {
        let router = ToolRouter(clock: { 500 }, allowedFindings: try awakeFindings())
        for finding in newFindings {
            let routed = router.route(report(finding))
            #expect(routed.proposal?.action == .reportFinding(finding, source: .heard, confidence: .high), "\(finding)")
            #expect(routed.response?.status == .received, "\(finding)")
        }
    }

    @Test func anAwakeSessionRefusesWhatItsContractOmits() throws {
        let allowed = try awakeFindings()
        #expect(allowed.count == 16)
        let router = ToolRouter(clock: { 500 }, allowedFindings: allowed)
        for finding in [Finding.responsive, .patientMoving, .breathingNormally, .emsArrived, .aedPrompting] {
            let routed = router.route(report(finding))
            #expect(routed.proposal == nil, "\(finding)")
            #expect(routed.response?.reason == .unknownValue, "\(finding)")
        }
        for finding in allowed {
            #expect(router.route(report(finding)).proposal != nil, "\(finding)")
        }
    }

    @Test func theAwakeContractLoadsTheSameWayAsTheArrestOne() throws {
        let awake = try LiveSetup.functionDeclarations(fromContract: try awakeContract())
        let arrest = try LiveSetup.functionDeclarations(fromContract: try toolContractData())
        func names(_ declarations: [JSONValue]) -> [JSONValue?] {
            declarations.map { declaration in
                guard case let .object(fields) = declaration else { return nil }
                return fields["name"]
            }
        }
        // report_scene is arrest only. On the awake model a tool call ends the turn.
        #expect(names(awake) == names(arrest).filter { $0 != "report_scene" })
    }
}
