import RescueCore
@testable import RescueLive
import Testing

/// press_button is for the app, like report_scene for the screen: it never becomes a proposal.
@Suite struct ToolRouterPressTests {
    private let router = ToolRouter(clock: { 0 })

    private func route(_ args: JSONValue) -> ToolRouter.Routed {
        router.route(RealtimeFunctionCall(id: "call-1", name: "press_button", args: args))
    }

    @Test func aKnownButtonDecodesToAPressAndNeverAProposal() {
        let routed = route(.object(["button": "called", "state_version": .number(4)]))
        #expect(routed.press == ButtonPress(action: .called, stateVersion: 4))
        #expect(routed.proposal == nil)
        #expect(routed.response?.status == .received)
    }

    @Test func anUnknownButtonAMissingVersionOrAnExtraArgumentIsRefused() {
        let bad: [JSONValue] = [
            .object(["button": "skip_everything", "state_version": .number(1)]),
            .object(["button": "yes"]),
            .object(["button": "yes", "state_version": .number(1), "reason": "they said so"]),
            .object(["button": "yes", "state_version": .number(-1)]),
        ]
        for args in bad {
            let routed = route(args)
            #expect(routed.press == nil, "\(args)")
            #expect(routed.response?.status == .rejected, "\(args)")
        }
    }
}
