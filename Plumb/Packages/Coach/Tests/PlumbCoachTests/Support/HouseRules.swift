import Foundation
import PlumbContracts
import Testing
@testable import PlumbCoach

/// Checks the promises that must hold on every look of every scenario, whatever the scenario is about.
func expectHouseRules(_ frames: [Bench.Frame], config: CuePolicy.Config = .init(),
                      sourceLocation: SourceLocation = #_sourceLocation) {
    // The voice never says something the screen is not showing.
    let mismatched = frames.filter { $0.speak != nil && $0.speak != $0.show }
    #expect(mismatched.isEmpty, "said one thing while showing another", sourceLocation: sourceLocation)

    let correctives = frames.spokenCorrectives
    for (earlier, later) in zip(correctives, correctives.dropFirst()) {
        #expect(later.t - earlier.t >= config.correctiveGapS,
                "\(later.cue) at \(later.t) came too soon after \(earlier.cue) at \(earlier.t)",
                sourceLocation: sourceLocation)
    }
    for cue in Cue.allCases {
        let times = correctives.filter { $0.cue == cue }.map(\.t)
        for (earlier, later) in zip(times, times.dropFirst()) {
            #expect(later - earlier >= config.sameCueGapS,
                    "\(cue) repeated after only \(later - earlier) s", sourceLocation: sourceLocation)
        }
    }
}
