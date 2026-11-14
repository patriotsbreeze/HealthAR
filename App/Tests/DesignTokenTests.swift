import Foundation
@testable import HealthAISim
import SwiftUI
import Testing
import UIKit

/// WCAG relative luminance, from the same hex values the views draw with.
private func luminance(_ hex: UInt32) -> Double {
    func channel(_ value: UInt32) -> Double {
        let c = Double(value & 0xFF) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
}

private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

@MainActor
@Suite struct DesignTokenTests {
    typealias Hex = DS.Hex

    /// 4.5:1 for text at body size, against what it sits on.
    @Test(arguments: [
        ("primary text on the deck", Hex.textPrimary, Hex.surface),
        ("secondary text on the deck", Hex.textSecondary, Hex.surface),
        ("secondary text on a row", Hex.textSecondary, Hex.surfaceRaised),
        ("critical text on the deck", Hex.critical, Hex.surface),
        ("critical text on a row", Hex.critical, Hex.surfaceRaised),
        ("caution text on the deck", Hex.caution, Hex.surface),
        ("ink on the strip", Hex.ink, Hex.caution),
        ("ink on the beat", Hex.ink, Hex.target),
        ("ink on a primary button", Hex.ink, Hex.primaryFill),
        ("white on Start CPR", Hex.textPrimary, Hex.criticalFill),
        ("white on a hold sweep", Hex.textPrimary, Hex.holdSweep),
    ])
    func textIsReadable(what: String, foreground: UInt32, background: UInt32) {
        #expect(contrast(foreground, background) >= 4.5, "\(what): \(contrast(foreground, background))")
    }

    /// 3:1 for shapes and large or bold text.
    @Test(arguments: [
        ("target", Hex.target), ("ok", Hex.ok), ("item", Hex.item), ("tertiary text", Hex.textTertiary),
    ])
    func marksStandOffTheDeck(what: String, color: UInt32) {
        #expect(contrast(color, Hex.surface) >= 3, "\(what): \(contrast(color, Hex.surface))")
    }

    /// Cyan on light skin is close to 1:1, so the keyline carries every mark.
    @Test func theTargetReadsAgainstItsKeyline() {
        #expect(contrast(Hex.target, 0x000000) >= 7)
        #expect(contrast(Hex.item, 0x000000) >= 7)
    }

    @Test func increaseContrastChangesWhatItShould() {
        let normal = UITraitCollection(accessibilityContrast: .normal)
        let high = UITraitCollection(accessibilityContrast: .high)
        for color in [DS.Colors.textSecondary, DS.Colors.hairline, DS.Colors.keyline] {
            let ui = UIColor(color)
            #expect(ui.resolvedColor(with: normal) != ui.resolvedColor(with: high))
        }
    }

    /// One meaning per color: no two meanings share a hue.
    @Test func everyMeaningHasItsOwnColor() {
        let meanings = [Hex.target, Hex.item, Hex.critical, Hex.caution, Hex.ok]
        #expect(Set(meanings).count == meanings.count)
    }

    // MARK: - Pinned words and sizes

    @Test func theGuardrailWordsStay() {
        #expect(SimulationStrip.text == "SIMULATION, will not call 911")
        #expect(SimulationStrip.badge == "OPERATOR USED")
        #expect(SimulationStrip.operatorHoldSeconds == 1.5)
        #expect(HoldButton.holdSeconds == 2)
        #expect(HoldButton.holdLine == "Hold 2 s")
        #expect(StopConfirmation.cancelTitle == "No, keep pushing")
        #expect(StopConfirmation.caution == "Only stop if this is true. Otherwise keep pushing.")
        #expect(HandoffCardView.draftLine == "DRAFT. AI-generated, not verified. Simulation only.")
        #expect(PadZonesGuide.caption == "Pad zones, coarse. Manikin only.")
        #expect(BeatPulse.label == "Push")
    }

    /// Compact for the camera, and never under the 44 pt a finger needs. A label that needs more grows the button, never the other way.
    @Test func buttonHeightsAreThePinnedOnes() {
        #expect(DS.Height.arrestPrimary == 64)
        #expect(DS.Height.arrest == 54)
        #expect(DS.Height.stopCancel == 96)
        #expect(DS.Height.stopConfirm == 84)
        #expect(DS.Height.awake == 50)
        #expect(DS.Height.awakeHold == 50)
        #expect(DS.Height.awakeWayOut == 52)
        #expect(DS.Height.camera == 44)
    }

    @Test func theBeatHasItsThreeSizes() {
        #expect(BeatPulse.standardDiameter == 170)
        #expect(DS.Pulse.docked == 96)
        #expect(DS.Pulse.sheet == 44)
    }

    /// The command never shrinks past 0.85 and stays Bold, and nothing anywhere is Heavy or Black.
    @Test func typeUsesThreeWeightsOnly() {
        let tokens = [
            DS.Fonts.command, DS.Fonts.commandCompact, DS.Fonts.confirm, DS.Fonts.title, DS.Fonts.detail, DS.Fonts.detailCompact,
            DS.Fonts.prompt, DS.Fonts.body, DS.Fonts.button, DS.Fonts.buttonTight, DS.Fonts.buttonCompact, DS.Fonts.buttonSmall, DS.Fonts.label, DS.Fonts.meta,
            DS.Fonts.caption, DS.Fonts.strip, DS.Fonts.badge, DS.Fonts.value,
        ]
        #expect(tokens.allSatisfy { [Font.Weight.regular, .semibold, .bold].contains($0.weight) })
        #expect(DS.Fonts.command.size == 26)
        #expect(DS.Fonts.command.weight == .bold)
        #expect(DS.Fonts.commandCompact.size == 24, "SAFETY.md holds a camera step's command at 24 pt")
    }

    @Test func dynamicTypeMovesTheTokens() {
        #expect(DS.Fonts.body.points(for: .large) == 17)
        #expect(DS.Fonts.body.points(for: .accessibility2) > DS.Fonts.body.points(for: .large))
    }

    @Test func theAlertSymbolsExist() {
        for symbol in ["phone.connection.fill", "pause.circle.fill", "speaker.badge.exclamationmark.fill", "mic.badge.xmark",
                       "mic.slash.fill", "waveform.badge.exclamationmark", "speaker.slash.fill", "ellipsis", "waveform", "ear",
                       "chevron.down", "chevron.right", "figure.seated.side.left", "sos.circle.fill",
                       "exclamationmark.triangle.fill", "hand.raised.fill", "list.bullet.rectangle",
                       "gauge.with.dots.needle.33percent", "checkmark.circle.fill"] {
            #expect(UIImage(systemName: symbol) != nil, "\(symbol)")
        }
    }
}
