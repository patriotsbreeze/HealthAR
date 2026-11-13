import RescueCore
import SwiftUI

/// The EMS card, rebuilt from the event log on every change. It never reads transcripts. Laid out like
/// a receipt: label on the left, value and time on the right, where each fact came from under it.
struct HandoffCardView: View {
    static let draftLine = "DRAFT. AI-generated, not verified. Simulation only."

    let coordinator: AppCoordinator

    var body: some View {
        let card = coordinator.handoffCard

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Handoff card")
                    .dsFont(DS.Fonts.title)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.draftLine)
                    .dsFont(DS.Fonts.label)
                    .foregroundStyle(DS.Colors.caution)
                    .padding(.top, DS.Space.xs)
                Button("Read card aloud") { coordinator.readAloud(card.readout) }
                    .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake))
                    .padding(.vertical, DS.Space.m)
                ForEach(Array(card.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { divider }
                    row(item)
                }
                SectionHeader(title: "Timeline")
                    .padding(.top, DS.Space.xl)
                    .padding(.bottom, DS.Space.xs)
                ForEach(Array(card.timeline.enumerated()), id: \.offset) { index, item in
                    if index > 0 { divider }
                    row(item)
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.deck, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.deck, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(DS.Colors.hairline).frame(height: 1)
    }

    private func row(_ item: HandoffCard.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Text(item.label)
                .dsFont(DS.Fonts.body)
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer(minLength: DS.Space.xs)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.value)
                    .dsFont(DS.Fonts.value)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .multilineTextAlignment(.trailing)
                HStack(spacing: 6) {
                    if let time = item.time {
                        Text(time)
                            .dsFont(DS.Fonts.meta)
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                    SourceTag(source: item.source)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Where a fact came from, muted. AI-inferred is the one that wants a second look, so it alone is in caution.
private struct SourceTag: View {
    let source: EvidenceSource?

    var body: some View {
        let caution = source == .aiInferred
        Text(Self.text(source))
            .dsFont(DS.Fonts.badge)
            .foregroundStyle(caution ? DS.Colors.caution : DS.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(caution ? DS.Colors.caution.opacity(0.7) : DS.Colors.hairline, lineWidth: 1))
    }

    static func text(_ source: EvidenceSource?) -> String {
        switch source {
        case .timer: "timer"
        case .sensor: "sensor"
        case .bystander: "bystander"
        case .aiInferred: "AI-inferred"
        case .system: "system"
        case nil: "none"
        }
    }
}
