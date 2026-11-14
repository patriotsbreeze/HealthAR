import Foundation
import RescueCore

/// One thing the AI has reported on the assess step, as the screen shows it. The words are fixed per
/// finding, so a report can only ever show as one of these, never as the AI's own phrasing.
struct AssessmentNote: Equatable, Identifiable {
    var finding: Finding
    var confidence: Confidence
    var source: ObservationSource
    var id: Finding { finding }

    /// "Possible" in the words, since none of this is a diagnosis.
    var label: String { Self.labels[finding] ?? "" }

    var certainty: String {
        switch confidence {
        case .low: "maybe"
        case .medium: "likely"
        case .high: "clearly"
        }
    }

    /// The reports that send the rescue toward CPR or danger steps, which show in the red meaning.
    var isUrgent: Bool { Self.urgent.contains(finding) }

    private static let labels: [Finding: String] = [
        .unresponsive: "Not responding",
        .notBreathing: "Not breathing",
        .abnormalBreathing: "Not breathing normally",
        .chestPain: "Possible chest pain",
        .otherHeartSigns: "Possible heart symptoms",
        .limbInjury: "Injured arm or leg",
        .limbDiscolored: "Limb looks discolored",
        .heavyBleeding: "Heavy bleeding",
        .neckBackInjury: "Possible neck or back injury",
        .choking: "Possible choking",
        .otherConcern: "Something else",
    ]

    private static let urgent: Set<Finding> = [.unresponsive, .notBreathing, .abnormalBreathing, .heavyBleeding, .choking]

    /// Each finding once, at the most sure it has been reported, newest first. Only since assess last
    /// opened, so a restart starts clean.
    static func notes(from entries: [LogEntry]) -> [AssessmentNote] {
        var notes: [AssessmentNote] = []
        for entry in entries {
            if entry.kind == .stateEntered {
                if entry.detail == ScenarioModule.assessState { notes = [] }
                continue
            }
            guard entry.kind == .observation, let note = parse(entry.detail) else { continue }
            let earlier = notes.firstIndex { $0.finding == note.finding }
            var merged = note
            if let earlier {
                let previous = notes.remove(at: earlier)
                if previous.confidence > note.confidence { merged.confidence = previous.confidence }
            }
            notes.insert(merged, at: 0)
        }
        return notes
    }

    /// The engine writes `finding,source,confidence`.
    private static func parse(_ detail: String?) -> AssessmentNote? {
        let parts = (detail ?? "").split(separator: ",").map(String.init)
        guard parts.count == 3,
              let finding = Finding(rawValue: parts[0]), labels[finding] != nil,
              let source = ObservationSource(rawValue: parts[1]),
              let confidence = Confidence(rawValue: parts[2])
        else { return nil }
        return AssessmentNote(finding: finding, confidence: confidence, source: source)
    }

    /// The last thing the AI said, so the screen shows what it's on now and not the whole run.
    static func lastSentence(of transcript: String) -> String? {
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
