import RescueCore
import SwiftUI

/// A guide card's words are its phrase's words, read from the bundle, so the card can't drift from
/// what the step says or add advice of its own.
enum GuideWords {
    static func phraseID(for guide: StateDefinition.Guide) -> String {
        switch guide {
        case .sitRest: "chest_sit"
        case .supportLimb: "limb_support"
        }
    }

    /// The first sentence leads and the rest follows, character for character.
    static func split(_ text: String) -> (title: String, detail: String?) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = line.firstIndex(where: { ".!?".contains($0) }), line.index(after: end) < line.endIndex else {
            return (line, nil)
        }
        let title = String(line[...end])
        let detail = line[line.index(after: end)...].trimmingCharacters(in: .whitespaces)
        return (title, detail.isEmpty ? nil : detail)
    }
}

/// The card for a state's guide, or nothing when its phrase didn't ship.
struct GuideCard: View {
    let guide: StateDefinition.Guide
    let bundle: ProtocolBundle
    /// The step's own line says the same words, so on a camera step the picture is enough.
    var pictureOnly = false

    var body: some View {
        if let text = bundle.text(forPhrase: GuideWords.phraseID(for: guide)) {
            let words = GuideWords.split(text)
            StepGuide(title: words.title, detail: words.detail, pictureOnly: pictureOnly) {
                switch guide {
                case .sitRest: SitRestPicture()
                case .supportLimb: SupportLimbPicture()
                }
            }
        }
    }
}

private struct StepGuide<Picture: View>: View {
    let title: String
    let detail: String?
    var pictureOnly = false
    @ViewBuilder let picture: Picture

    var body: some View {
        HStack(spacing: DS.Space.m) {
            picture.frame(width: 72, height: 56)
            if !pictureOnly {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .dsFont(DS.Fonts.label)
                        .foregroundStyle(DS.Colors.textPrimary)
                    if let detail {
                        Text(detail)
                            .dsFont(DS.Fonts.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: pictureOnly ? nil : .infinity)
        .glassSurface(RoundedRectangle(cornerRadius: DS.Radius.row + 4, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(detail.map { "\(title) \($0)" } ?? title)
    }
}

/// A neutral posture, so the picture adds nothing beyond the phrase.
private struct SitRestPicture: View {
    var body: some View {
        Image(systemName: "figure.seated.side.left")
            .font(.system(size: 36, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(DS.Colors.textPrimary)
    }
}

/// The AR's own meanings: the thing to grab in white, the limb in the target color, lying on it
/// with a slight bend, because it stays however it was found.
private struct SupportLimbPicture: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let base = Path(roundedRect: CGRect(x: 0.06 * w, y: 0.60 * h, width: 0.88 * w, height: 0.26 * h), cornerRadius: 0.08 * h, style: .continuous)
            let fold = Path(roundedRect: CGRect(x: 0.10 * w, y: 0.50 * h, width: 0.80 * w, height: 0.18 * h), cornerRadius: 0.07 * h, style: .continuous)
            for (path, fill) in [(base, 0.16), (fold, 0.10)] {
                context.fill(path, with: .color(DS.Colors.item.opacity(fill)))
                context.stroke(path, with: .color(DS.Colors.item), lineWidth: 1.5)
            }
            let limb = ARGeometry.segmentCapsule(from: CGPoint(x: 0.14 * w, y: 0.42 * h), to: CGPoint(x: 0.62 * w, y: 0.42 * h), width: 0.16 * h)
                .union(ARGeometry.segmentCapsule(from: CGPoint(x: 0.62 * w, y: 0.42 * h), to: CGPoint(x: 0.86 * w, y: 0.20 * h), width: 0.14 * h))
            context.fill(limb, with: .color(DS.Colors.target.opacity(DS.AR.fill)))
            context.stroke(limb, with: .color(DS.Colors.target), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
        }
    }
}

/// Coarse and static. Shown on the pads step whenever pads aren't drawn on the body.
struct PadZonesGuide: View {
    static let caption = ARSceneBuilder.padsCaption

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in PadDiagram.paint(in: CGRect(origin: .zero, size: size), context: &context) }
                .aspectRatio(120.0 / 150.0, contentMode: .fit)
                .frame(maxWidth: 120, maxHeight: 150)
            Text(Self.caption)
                .dsFont(DS.Fonts.meta)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: 150)
        .padding(10)
        .glassSurface(RoundedRectangle(cornerRadius: DS.Radius.row + 4, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Coarse pad zones: upper right chest and lower left side. Manikin only.")
    }
}

enum PadDiagram {
    /// The patient's right is on the viewer's left. Pad 1 under the right collarbone, pad 2 low on the left side.
    static func paint(in rect: CGRect, context: inout GraphicsContext) {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        var torso = Path()
        torso.move(to: p(0.38, 0.04))
        torso.addQuadCurve(to: p(0.08, 0.14), control: p(0.18, 0.05))
        torso.addLine(to: p(0.10, 0.34))
        torso.addQuadCurve(to: p(0.22, 0.96), control: p(0.14, 0.70))
        torso.addLine(to: p(0.78, 0.96))
        torso.addQuadCurve(to: p(0.90, 0.34), control: p(0.86, 0.70))
        torso.addLine(to: p(0.92, 0.14))
        torso.addQuadCurve(to: p(0.62, 0.04), control: p(0.82, 0.05))
        torso.addQuadCurve(to: p(0.38, 0.04), control: p(0.50, 0.12))
        torso.closeSubpath()
        context.stroke(torso, with: .color(DS.Colors.textSecondary), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        let size = CGSize(width: 0.24 * w, height: 0.24 * w * 1.4)
        let pads: [(Int, CGPoint, Double)] = [(1, p(0.33, 0.30), 0), (2, p(0.72, 0.64), .pi / 12)]
        for (number, center, angle) in pads {
            let pad = ARGeometry.pad(center: center, size: size, angle: angle)
            context.fill(pad, with: .color(DS.Colors.target.opacity(DS.AR.fill)))
            context.stroke(pad, with: .color(DS.Colors.target), lineWidth: 2.5)
            ARPainter.numeral(number, at: center, diameter: min(22, size.width * 0.8), in: &context)
        }
    }
}
