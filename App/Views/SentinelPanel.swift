import RescueCore
import SwiftUI

/// The three lanes, for the pitch. Everything but the Voice lane's transcripts comes from the log.
struct SentinelPanel: View {
    let coordinator: AppCoordinator
    var onOperator: (() -> Void)?

    private struct Row: Identifiable {
        var id: Int
        var time: String
        var text: String
        var seeded: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetTopBar(coordinator: coordinator, onOperator: onOperator)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Sentinel")
                            .dsFont(DS.Fonts.title)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Sentinel constrains the AI voice in layers. It cannot prevent a wrong line: speech is heard before it is checked, and transcripts may include words never spoken.")
                            .dsFont(DS.Fonts.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    lane("Voice", subtitle: "Gemini Live, what the model reported and said", rows: voiceRows) {
                        if !coordinator.heardTranscript.isEmpty {
                            transcript("Heard", coordinator.heardTranscript)
                        }
                        if !coordinator.saidTranscript.isEmpty {
                            transcript("Said", coordinator.saidTranscript)
                        }
                    }
                    lane("Sentinel", subtitle: "Rejected proposals and transcript flags", rows: sentinelRows)
                    lane("Protocol", subtitle: "On-device engine, the only thing that decides", rows: protocolRows)
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.Colors.surface)
        .presentationBackground(DS.Colors.surface)
        .presentationDetents([.medium, .large])
        // The grabber would sit on the strip's words. The sheet still drags.
        .presentationDragIndicator(.hidden)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private var startedAt: TimeInterval { coordinator.log.entries.first?.at ?? coordinator.state.startedAt }

    private var voiceRows: [Row] {
        coordinator.modelCalls.reversed().map { call in
            Row(id: call.id, time: clockText(call.at - startedAt), text: call.summary, seeded: call.seeded)
        }
    }

    private var sentinelRows: [Row] {
        rows(kinds: [.proposalRejected, .sentinelFlag], limit: 30) { entry in
            entry.kind == .proposalRejected ? "Rejected \(entry.detail)" : "Flagged \(entry.detail)"
        }
    }

    private var protocolRows: [Row] {
        rows(kinds: [.stateEntered, .phrasePlayed], limit: 12) { entry in
            entry.kind == .stateEntered ? "State \(entry.detail)" : "Played \(entry.detail)"
        }
    }

    private func rows(kinds: Set<LogEntry.Kind>, limit: Int, text: (LogEntry) -> String) -> [Row] {
        coordinator.log.entries
            .filter { kinds.contains($0.kind) }
            .suffix(limit)
            .reversed()
            .map { entry in
                Row(
                    id: entry.seq,
                    time: clockText(entry.at - startedAt),
                    text: text(entry),
                    seeded: coordinator.seededSequences.contains(entry.seq)
                )
            }
    }

    private func lane(
        _ title: String,
        subtitle: String,
        rows: [Row],
        @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        // A section, not a card: the sheet is already the surface.
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .dsFont(DS.Fonts.prompt)
                .foregroundStyle(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .dsFont(DS.Fonts.meta)
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.bottom, DS.Space.s)
            extra()
            if rows.isEmpty {
                Text("Nothing yet")
                    .dsFont(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.textTertiary)
                    .padding(.vertical, 6)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Rectangle().fill(DS.Colors.hairline).frame(height: 1) }
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(row.time)
                        .dsFont(DS.Fonts.meta)
                        .foregroundStyle(DS.Colors.textSecondary)
                    Text(row.text)
                        .dsFont(DS.Fonts.body)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Spacer(minLength: 0)
                    if row.seeded {
                        // In capitals, as the stage script reads it.
                        Text("SEEDED")
                            .dsFont(DS.Fonts.badge)
                            .foregroundStyle(DS.Colors.caution)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(DS.Colors.caution, lineWidth: 1))
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transcript(_ label: String, _ text: String) -> some View {
        Text("\(Text("\(label):").bold()) \(text)")
            .dsFont(DS.Fonts.caption)
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.bottom, DS.Space.s)
    }
}
