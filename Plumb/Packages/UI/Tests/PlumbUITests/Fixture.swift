import Foundation
import PlumbContracts
import SwiftUI
@testable import PlumbUI

/// Made-up sessions for tests and pictures, all derived from `SyntheticSession` so they are the same on every run.
@MainActor
enum Fixture {
    /// The instant every made-up frame is drawn at.
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A flat dark stand-in for the camera and depth pictures. Not a palette colour: it is not part of the app.
    static let pictureSwatch = Theme.Swatch(hex: 0x1B1D22)
    static let picture = pictureSwatch.color

    /// Finished pushes from a made-up session, with a little seeded scatter so they look measured.
    static func bars(_ segments: [SyntheticSegment], trust: LockState = .locked, seed: UInt64 = 11,
                     scatterMM: Double = 1.6) -> [StrokeBar] {
        strokes(segments, trust: trust, seed: seed, scatterMM: scatterMM).map(\.bar)
    }

    /// The same pushes with the time of each.
    static func strokes(_ segments: [SyntheticSegment], trust: LockState = .locked, seed: UInt64 = 11,
                        scatterMM: Double = 1.6) -> [WorkingTimeline.Stroke] {
        var generator = SplitMix64(seed: seed)
        return SyntheticSession.truth(segments).bottoms.map { bottom in
            let depth = bottom.depthMM + scatterMM * generator.nextGaussian()
            let bar = StrokeBar(depthMM: depth, reached: depth >= Targets.adult.depthMinMM, trust: trust)
            return WorkingTimeline.Stroke(t: bottom.t, bar: bar)
        }
    }

    /// A model holding `bars`, the newest of which arrived `settledFor` seconds before `now`.
    static func model(_ bars: [StrokeBar], liveDepthMM: Double = 0, trust: LockState = .locked,
                      settledFor: TimeInterval = 5) -> BarFieldModel {
        let model = BarFieldModel()
        for bar in bars {
            model.append(bar, at: now.addingTimeInterval(-settledFor))
        }
        model.liveDepthMM = liveDepthMM
        model.trust = trust
        return model
    }

    /// The opening of the demo session: too shallow.
    static let shallow = Array(SyntheticSession.demo.prefix(2))
    /// The demo session up to the point where the pushes have come good.
    static let corrected = Array(SyntheticSession.demo.prefix(3))

    static func panel(command: String? = nil, tone: CommandTone = .fix, startPrompt: String? = nil,
                      model: BarFieldModel, rate: Double?, rateInRange: Bool = true,
                      elapsedSeconds: Double, onCheckChest: (() -> Void)? = nil) -> CoachPanel {
        CoachPanel(command: command, tone: tone, startPrompt: startPrompt, model: model, rate: rate,
                   rateInRange: rateInRange, elapsedSeconds: elapsedSeconds,
                   onAskChanged: { _ in }, onFindAED: {}, onShowWorking: {}, onCheckChest: onCheckChest)
    }

    static func rescue(_ panel: CoachPanel) -> some View {
        RescueScreen(panel: panel) { picture }
            .environment(\.barFieldStillDate, now)
    }
}
