import Foundation
import PlumbContracts
import SwiftUI
@testable import PlumbUI

/// Made-up chest traces and screens for tests and pictures, the same on every run.
@MainActor
enum ChestFixture {
    /// Values in a trace: thirty seconds, ten a second, as the chest check hands them over.
    static let slots = 300
    /// Share of the trace the band covers: the last eight of thirty seconds.
    static let bandShare = 8.0 / 30
    /// The band around a still chest at the threshold of 2.4 mm.
    nonisolated static let band = -1.2...1.2

    /// A chest moving fifteen times a minute, 4 mm either way, for `moving` values, then held still at zero,
    /// with a little seeded noise. The first `unmeasured` values are nil.
    static func trace(unmeasured: Int = 0, moving: Int, seed: UInt64 = 41) -> [Double?] {
        var generator = SplitMix64(seed: seed)
        return (0..<slots).map { index -> Double? in
            guard index >= unmeasured else { return nil }
            let local = Double(index - unmeasured) * 0.1
            let movement = index - unmeasured < moving ? 4 * sin(2 * .pi * 0.25 * local) : 0
            return movement + 0.15 * generator.nextGaussian()
        }
    }

    static func screen(status: String, command: String? = nil, context: String? = nil,
                       trace: [Double?], band: ClosedRange<Double>? = band) -> some View {
        ChestScreen(status: status, command: command, context: context, trace: trace, band: band,
                    bandShare: bandShare, onStartPushing: {}, onBack: {}) { Fixture.picture }
    }

    /// Before anything is tapped: nothing measured, nothing drawn.
    static var tapTheChest: some View {
        screen(status: "Looking for the chest", context: "Tap the chest on the picture",
               trace: Array(repeating: nil, count: slots), band: nil)
    }

    static var movementSeen: some View {
        screen(status: "Chest movement seen", trace: trace(unmeasured: 80, moving: .max), band: -1.4...1.0)
    }

    static var startPushing: some View {
        screen(status: "No chest movement seen for 12\u{00A0}s", command: "Start pushing",
               context: "No chest movement seen for 12\u{00A0}s", trace: trace(moving: 160))
    }

    static var movementAfterThePrompt: some View {
        screen(status: "Chest movement seen", command: "Start pushing", context: "Chest movement seen",
               trace: trace(moving: 120).enumerated().map { index, value in
                   index > 250 ? (value ?? 0) + 4 * sin(2 * .pi * 0.25 * Double(index - 250) * 0.1) : value
               })
    }
}
