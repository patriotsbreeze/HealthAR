import Foundation
import Network
import Testing
@testable import PlumbAgents

@Suite struct NetworkWatchTests {
    @Test func itCountsAsOfflineUntilAPathIsReported() {
        #expect(!NetworkWatch(monitor: nil).isOnline)
    }

    @Test func onlyAUsablePathCountsAsOnline() {
        let watch = NetworkWatch(monitor: nil)

        watch.record(.satisfied)
        #expect(watch.isOnline)
        watch.record(.requiresConnection)
        #expect(!watch.isOnline)
        watch.record(.satisfied)
        watch.record(.unsatisfied)
        #expect(!watch.isOnline)
    }

    @Test func changesAreSentOnceEach() async {
        let watch = NetworkWatch(monitor: nil)
        let seen = Locked<[Bool]>([])
        let listening = Task {
            for await online in watch.changes {
                seen.with { $0.append(online) }
            }
        }

        for status in [NWPath.Status.unsatisfied, .satisfied, .satisfied, .requiresConnection, .unsatisfied, .satisfied] {
            watch.record(status)
        }

        #expect(await eventually { seen.current.count == 3 })
        #expect(seen.current == [true, false, true])
        listening.cancel()
    }

    @Test func theLiveVoiceNeedsANetworkAKeyAndAnOpenConnection() {
        #expect(AskRoute.choose(isOnline: true, hasKey: true, voiceConnected: true) == .live)
        for isOnline in [true, false] {
            for hasKey in [true, false] {
                for voiceConnected in [true, false] where !(isOnline && hasKey && voiceConnected) {
                    #expect(AskRoute.choose(isOnline: isOnline, hasKey: hasKey, voiceConnected: voiceConnected)
                        == .onDevice)
                }
            }
        }
    }

    /// Online with a key, but the voice's connection still opening or dropped: the press is answered on
    /// the phone rather than lost.
    @Test func aPressWhileTheVoiceIsNotConnectedIsAnsweredOnThePhone() {
        #expect(AskRoute.choose(isOnline: true, hasKey: true, voiceConnected: false) == .onDevice)
    }
}
