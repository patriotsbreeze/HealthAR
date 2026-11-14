import RescueLive
import RescueVision
import SwiftUI

/// Measured numbers only. What hasn't been measured reads "not measured", never zero.
struct LatencyHUD: View {
    let coordinator: AppCoordinator

    private static let metrics: [(LiveTimingMetric, String)] = [
        (.setup, "Live setup"),
        (.reconnectGap, "Reconnect gap"),
        (.modeSwap, "Mode swap"),
        (.speechEndToToolCall, "Speech end to tool"),
        (.speechEndToModelAudio, "Speech end to voice"),
    ]

    /// A rescue that never swaps has no swap to measure, and its HUD reads as it always has.
    static func metrics(for timings: [LiveTimingMetric: [TimeInterval]]) -> [(LiveTimingMetric, String)] {
        metrics.filter { $0.0 != .modeSwap || timings[.modeSwap] != nil }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.metrics(for: coordinator.timings), id: \.0) { metric, label in
                    line(label, Self.summary(coordinator.timings[metric] ?? []))
                }
                line("Keypoint age", coordinator.vision.keypointAge.map(Self.milliseconds) ?? "not measured")
                line("AR", arText)
                line("AED locate", coordinator.vision.aedStatus.rawValue)
                let reads = coordinator.assessmentStats
                line("Live scene gap", Self.summary(reads.liveGaps))
                line("Quick look", Self.summary(reads.quick))
                if reads.failures > 0 {
                    line("Scene read failures", "\(reads.failures), last \(reads.lastProblem ?? "unknown")")
                }
                if let tokens = coordinator.usage?.totalTokens {
                    line("Tokens", String(tokens))
                }
                if let reason = coordinator.lastDisconnect {
                    line("Last disconnect", reason)
                }
                if let mic = coordinator.micProblem {
                    line("Mic", mic)
                }
            }
        }
        .dsFont(DS.Fonts.meta)
        .foregroundStyle(DS.Colors.textPrimary)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1))
        .padding(.horizontal, DS.Space.deckInset)
        .accessibilityElement(children: .combine)
    }

    private var arText: String {
        var text = coordinator.visionStatus.rawValue
        if coordinator.overlayTarget == .chestCenter, let reason = coordinator.vision.lastNoTargetReason {
            text += ", \(reason.rawValue)"
        }
        return text
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(DS.Colors.textSecondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    /// M3's bar is on the median, so that is shown beside the latest.
    static func summary(_ values: [TimeInterval]) -> String {
        guard let last = values.last else { return "not measured" }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return "last \(milliseconds(last)), median \(milliseconds(median)), n=\(values.count)"
    }

    private static func milliseconds(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }
}
