import RescueCore
import RescueVision
import SwiftUI

/// What each part of the app is doing right now, one card each. Only parts that really run are here,
/// and each says what it can't do, so nothing reads as more than it is.
struct AgentsSheet: View {
    let coordinator: AppCoordinator
    var onOperator: (() -> Void)?

    private enum Activity {
        case active, working, idle, off

        var color: Color {
            switch self {
            case .active: DS.Colors.ok
            case .working: Color(hex: 0x6E9BF2)
            case .idle: DS.Colors.textSecondary
            case .off: DS.Colors.textTertiary
            }
        }
    }

    private struct Agent: Identifiable {
        var id: String { name }
        var name: String
        var symbol: String
        var engine: String
        var status: String
        var activity: Activity
        var detail: String
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetTopBar(coordinator: coordinator, onOperator: onOperator)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Agents")
                            .dsFont(DS.Fonts.title)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("The AI parts report what they hear and see. Only the on-device protocol decides the next step.")
                            .dsFont(DS.Fonts.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    // The AED finder's status lives in vision, which nothing here observes.
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack(spacing: DS.Space.s) {
                            ForEach(agents) { card($0) }
                        }
                    }
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.Colors.surface)
        .presentationBackground(DS.Colors.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private var agents: [Agent] { [voice, safety, aedFinder, dispatcher, protocolEngine] }

    // MARK: - The agents

    private var voice: Agent {
        let awake = coordinator.definition?.kind.isAwake == true
        let status: String
        let activity: Activity
        if !coordinator.liveConnected {
            status = coordinator.liveSwapping ? "Switching…" : "Offline"
            activity = coordinator.liveSwapping ? .working : .off
        } else if coordinator.aiTalking {
            (status, activity) = ("Talking…", .working)
        } else if coordinator.aiListening {
            (status, activity) = ("Listening…", .active)
        } else if coordinator.state.callActive {
            (status, activity) = ("Paused for call", .idle)
        } else {
            (status, activity) = ("Connected", .idle)
        }
        let said = lastSentence(of: coordinator.saidTranscript)
        let detail = said.map { "“\($0)”" } ?? coordinator.modelCalls.last?.summary ?? "Nothing said yet"
        return Agent(
            name: "Voice guide", symbol: "waveform",
            engine: "Gemini Live, \(awake ? "awake" : "arrest") session",
            status: status, activity: activity, detail: detail
        )
    }

    private var safety: Agent {
        let caught = coordinator.log.entries.filter { $0.kind == .proposalRejected || $0.kind == .sentinelFlag }
        let detail: String
        if let last = caught.last {
            let verb = last.kind == .proposalRejected ? "Rejected" : "Flagged"
            detail = "\(verb): \(readable(last.detail))"
        } else {
            detail = "Nothing caught yet"
        }
        let status = caught.isEmpty ? (coordinator.liveConnected ? "Watching" : "Idle") : "\(caught.count) caught"
        let activity: Activity = coordinator.liveConnected ? .active : .idle
        return Agent(
            name: "Safety checker", symbol: "checkmark.shield",
            engine: "Gemini Flash-Lite and on-device rules",
            status: status, activity: activity, detail: detail
        )
    }

    private var aedFinder: Agent {
        let engine = "Gemini Flash, one camera frame at a time"
        guard coordinator.aedFinderAvailable else {
            return Agent(
                name: "AED finder", symbol: "viewfinder", engine: engine,
                status: "Off", activity: .off, detail: "Needs the camera and an API key"
            )
        }
        let (status, activity, detail): (String, Activity, String) = switch coordinator.vision.aedStatus {
        case .idle: ("Standing by", .idle, "Looks when the guide or a scan step asks")
        case .locating: ("Searching…", .working, "Checking a camera frame for an AED")
        case .located: ("Found", .active, "Marked on screen with an arrow")
        case .notFound: ("Not found", .idle, "Nothing in the last frame. Pan the room")
        case .noSurface: ("No surface", .idle, "Seen, but couldn't place it. Point at the floor")
        case .unreliablePose: ("Hold steady", .idle, "The camera moved too much to place it")
        }
        return Agent(name: "AED finder", symbol: "viewfinder", engine: engine, status: status, activity: activity, detail: detail)
    }

    private var dispatcher: Agent {
        let status: String
        let activity: Activity
        if coordinator.state.callActive {
            (status, activity) = ("On call", .active)
        } else if coordinator.dispatcherOpen {
            (status, activity) = ("Open", .active)
        } else {
            (status, activity) = ("Ready", .idle)
        }
        return Agent(
            name: "911 script", symbol: "phone",
            engine: "Mock dispatcher. Never places a call",
            status: status, activity: activity, detail: coordinator.callerScript.situation
        )
    }

    private var protocolEngine: Agent {
        let step = readable(coordinator.state.stateID)
        let changes = coordinator.log.entries.filter { $0.kind == .stateEntered }.count
        return Agent(
            name: "Protocol engine", symbol: "list.number",
            engine: "On-device, works offline",
            status: step, activity: .active,
            detail: "Decides every step. \(changes) step\(changes == 1 ? "" : "s") so far"
        )
    }

    // MARK: - Drawing

    private func card(_ agent: Agent) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: agent.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .frame(width: 36, height: 36)
                .background(DS.Colors.surfaceRaised, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(agent.name)
                        .dsFont(DS.Fonts.prompt)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Spacer(minLength: 0)
                    statusBadge(agent)
                }
                Text(agent.engine)
                    .dsFont(DS.Fonts.meta)
                    .foregroundStyle(DS.Colors.textTertiary)
                Text(agent.detail)
                    .dsFont(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(3)
                    .padding(.top, DS.Space.xs)
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func statusBadge(_ agent: Agent) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(agent.activity.color)
                .frame(width: 8, height: 8)
            Text(agent.status)
                .dsFont(DS.Fonts.label)
                .foregroundStyle(agent.activity == .off ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - Text

    /// "call_911" reads as "Call 911".
    private func readable(_ id: String) -> String {
        let words = id.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The last thing the voice said, so the card shows what it's on now and not the whole run.
    private func lastSentence(of transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        return sentences.last ?? trimmed
    }
}
