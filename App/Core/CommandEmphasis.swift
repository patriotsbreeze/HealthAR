import Foundation
import RescueCore
import SwiftUI

/// Ties the command's words to the camera: the body part to act on in the target color, the thing to
/// grab in item white. The characters never change, so the pinned phrase text and what VoiceOver reads
/// stay exactly the phrase. It follows the step's data, not tracking, so it never flickers.
enum CommandEmphasis {
    struct Terms: Equatable {
        var body: [String] = []
        var item: [String] = []

        var isEmpty: Bool { body.isEmpty && item.isEmpty }
    }

    /// Longest first, so "center of the chest" wins over "chest".
    static func terms(target: OverlayTarget?, bodies: [Cue.Body] = [], materials: [RescueCore.Material] = []) -> Terms {
        var terms = Terms()
        switch target {
        case .chestCenter: terms.body = ["center of the chest", "chest"]
        case .padZones:
            terms.body = ["chest"]
            terms.item = ["pads"]
        case .injurySite: terms.body = ["limb", "injury"]
        case .aedDevice: terms.item = ["AED"]
        case nil: break
        }
        for body in bodies {
            for noun in nouns(for: body) where !terms.body.contains(noun) {
                terms.body.append(noun)
            }
        }
        for material in materials {
            for noun in nouns(for: material) where !terms.item.contains(noun) {
                terms.item.append(noun)
            }
        }
        terms.body.sort { $0.count > $1.count }
        terms.item.sort { $0.count > $1.count }
        return terms
    }

    /// Where a cue's mark lands, in the words the steps use for it. No default, for the same reason.
    static func nouns(for body: Cue.Body) -> [String] {
        switch body {
        case .injuredLimb: ["limb", "arm", "leg"]
        case .injurySite: ["bleeding", "wound", "injury"]
        }
    }

    /// No default, so a new material can't ship without its words.
    static func nouns(for material: RescueCore.Material) -> [String] {
        switch material {
        case .aed: ["AED"]
        case .towel, .pillow, .gloves: material.calloutNouns.sorted()
        }
    }

    static func attributed(_ text: String, terms: Terms) -> AttributedString {
        var result = AttributedString(text)
        guard !terms.isEmpty else { return result }
        var taken: [Range<String.Index>] = []
        // Body first: where both could match, the place to act matters more.
        if let range = firstWholeWord(in: text, from: terms.body, avoiding: taken), let span = Range(range, in: result) {
            result[span].foregroundColor = DS.Colors.target
            result[span].inlinePresentationIntent = .stronglyEmphasized
            taken.append(range)
        }
        if let range = firstWholeWord(in: text, from: terms.item, avoiding: taken), let span = Range(range, in: result) {
            result[span].foregroundColor = DS.Colors.item
            result[span].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }

    /// The earliest match of any term, as a whole word: "arm" never lights up inside "alarm".
    static func firstWholeWord(in text: String, from terms: [String], avoiding taken: [Range<String.Index>] = []) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for term in terms where !term.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
                let whole = !(before?.isLetter ?? false) && !(after?.isLetter ?? false)
                if whole, !taken.contains(where: { $0.overlaps(range) }) {
                    if best.map({ range.lowerBound < $0.lowerBound }) ?? true { best = range }
                    break
                }
                searchStart = range.upperBound
            }
        }
        return best
    }
}
