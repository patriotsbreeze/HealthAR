import SwiftUI

/// Draws a scene into one Canvas. Every stroke is four layers: a wide 40% black under-stroke, the fill,
/// a black keyline, then the color. No blur and no glow, so it costs nothing on a phone that is
/// already running ARKit, Vision and audio, and it reads on light skin, dark skin and white sheets.
enum ARPainter {
    struct Style {
        var typeSize: DynamicTypeSize
        var reduceMotion: Bool
    }

    static func paint(_ scene: ARScene, appear: [String: Double], style: Style, in context: inout GraphicsContext) {
        guard scene.hasMarks || scene.hint != nil else { return }
        // Nothing is drawn under the deck. A body zone that runs past the band is cut at its edge.
        context.clip(to: Path(scene.band))
        if let ghost = scene.ghost { paintGhost(ghost, in: &context) }
        if let outline = scene.outline {
            appearing(appear[ARSceneBuilder.outlineID], around: outline.center, style: style, in: &context) { layer in
                paintOutline(outline, in: &layer)
            }
        }
        if let zone = scene.zone {
            appearing(appear[zone.id], around: zone.center, style: style, in: &context) { layer in
                paintZone(zone, handsIn3D: scene.handsIn3D, in: &layer)
            }
        }
        for item in scene.items {
            appearing(appear[item.id], around: CGPoint(x: item.frame.midX, y: item.frame.midY), style: style, in: &context) { layer in
                paintItem(item, in: &layer)
            }
        }
        if let pointer = scene.pointer { paintPointer(pointer, style: style, in: &context) }
        for point in scene.joints {
            let dot = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            context.stroke(dot, with: .color(.black.opacity(0.7)), lineWidth: 3)
            context.fill(dot, with: .color(.blue))
        }
        if let zoneChip = scene.zone?.chip { chip(zoneChip, style: style, in: &context) }
        for case let itemChip? in scene.items.map(\.chip) { chip(itemChip, style: style, in: &context) }
        if let hint = scene.hint { chip(hint, style: style, in: &context) }
    }

    /// First lock only: 0.28 s from a touch larger and clear to in place. Under Reduce Motion it only fades.
    private static func appearing(
        _ progress: Double?,
        around center: CGPoint,
        style: Style,
        in context: inout GraphicsContext,
        draw: (inout GraphicsContext) -> Void
    ) {
        guard let progress, progress < 1 else {
            draw(&context)
            return
        }
        let eased = 1 - pow(1 - max(0, progress), 3)
        var layer = context
        layer.opacity = eased
        if !style.reduceMotion {
            let scale = DS.Motion.lockScale - (DS.Motion.lockScale - 1) * eased
            layer.translateBy(x: center.x, y: center.y)
            layer.scaleBy(x: scale, y: scale)
            layer.translateBy(x: -center.x, y: -center.y)
        }
        draw(&layer)
    }

    // MARK: - Zones

    static func zoneLayers(_ path: Path, lock: ARLock, fill: Double = DS.AR.fill, color: Color = DS.Colors.target, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(DS.Colors.underStroke), style: solid(DS.AR.underWidth))
        context.fill(path, with: .color(color.opacity(fill)))
        context.stroke(path, with: .color(DS.Colors.keyline), style: solid(DS.AR.keylineWidth))
        context.stroke(path, with: .color(color), style: colorStroke(DS.AR.strokeWidth, lock: lock, size: path.boundingRect.size))
    }

    private static func solid(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    /// The colored stroke, the only layer that dashes, so "estimating" breaks up the color over a
    /// dark rim that stays whole. Round caps grow each dash by the stroke's width, so the pattern
    /// drawn is shortened by that much to look as `DS.AR.dash` says.
    static func colorStroke(_ width: CGFloat, lock: ARLock, size: CGSize) -> StrokeStyle {
        guard lock == .estimating else { return StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
        let looks = max(size.width, size.height) < DS.AR.dashSmallBelow ? DS.AR.dashSmall : DS.AR.dash
        return StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: [max(0.5, looks[0] - width), looks[1] + width])
    }

    private static func paintZone(_ zone: ARZone, handsIn3D: Bool, in context: inout GraphicsContext) {
        switch zone.shape {
        case let .chest(center, _, _, _, palm, fingers):
            zoneLayers(zone.path, lock: zone.lock, in: &context)
            if handsIn3D { break }
            let hands = ARGeometry.ghostHands(heel: center, fingerAngle: fingers, palmRadius: palm)
            // The lower hand whole, then the upper one on a solid base, so where they overlap the upper
            // hand lies on top and the pair reads as two hands stacked.
            for (path, fill, base) in [(hands.under, DS.AR.underHandFill, 0.0), (hands.over, DS.AR.fill, DS.AR.overHandBase)] {
                if base > 0 { context.fill(path, with: .color(DS.Colors.surface.opacity(base))) }
                context.fill(path, with: .color(DS.Colors.target.opacity(fill)))
                context.stroke(path, with: .color(DS.Colors.keyline), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
                context.stroke(path, with: .color(DS.Colors.target), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            // The heel of the hand is the point of it all.
            context.fill(hands.heelPad, with: .color(DS.Colors.target.opacity(DS.AR.heelFill)))
        case let .pads(pads):
            for pad in pads {
                zoneLayers(ARGeometry.pad(center: pad.center, size: pad.size, angle: pad.angle), lock: zone.lock, in: &context)
            }
            for pad in pads {
                numeral(pad.number, at: pad.center, diameter: min(26, max(18, pad.size.width * 0.6)), in: &context)
            }
        case .limb, .press:
            zoneLayers(zone.path, lock: zone.lock, in: &context)
        }
    }

    /// One silhouette, not a pile of shapes: every part's line is drawn, then every part's inside is cut
    /// out of the lines, so only the body's edge is left, solid or dashed part by part. The fill goes in
    /// once over the whole body, so where a limb lies on the torso it doesn't read darker.
    private static func paintOutline(_ outline: AROutline, in context: inout GraphicsContext) {
        // Opacity on the context a layer is drawn into fades the layer whole. Set inside, it would fade
        // each shape, and overlaps would stack.
        var fill = context
        fill.opacity *= DS.AR.Outline.fill
        fill.drawLayer { layer in
            for part in outline.parts { layer.fill(part.path, with: .color(DS.AR.Outline.color)) }
        }
        var lines = context
        lines.opacity *= DS.AR.Outline.opacity
        lines.drawLayer { layer in
            for part in outline.parts {
                layer.stroke(part.path, with: .color(DS.Colors.keyline), style: solid(DS.AR.Outline.keyline))
            }
            for part in outline.parts {
                let style = colorStroke(DS.AR.Outline.stroke, lock: part.lock, size: part.path.boundingRect.size)
                layer.stroke(part.path, with: .color(DS.AR.Outline.color), style: style)
            }
            // Part by part: one path of them all could cancel where two wind opposite ways.
            layer.blendMode = .destinationOut
            for part in outline.parts { layer.fill(part.path, with: .color(.black)) }
        }
    }

    /// The bodies are 3D, drawn by the AR view itself. Over them only the hands' ring, strong on the click.
    private static func paintGhost(_ ghost: ARGhost, in context: inout GraphicsContext) {
        if let hands = ghost.rescuer.hands, ghost.push > 0.5 {
            let size = DS.AR.Ghost.pressRing * (1 + 0.4 * ghost.push)
            let ring = Path(ellipseIn: CGRect(center: hands, size: CGSize(width: size, height: size)))
            context.stroke(ring, with: .color(DS.Colors.target.opacity((ghost.push - 0.5) * 2)), lineWidth: DS.AR.Ghost.pressRingWidth)
        }
    }

    /// A pad's number on a solid disc.
    static func numeral(_ number: Int, at center: CGPoint, diameter: CGFloat, in context: inout GraphicsContext) {
        let disc = Path(ellipseIn: CGRect(center: center, size: CGSize(width: diameter, height: diameter)))
        context.fill(disc, with: .color(DS.Colors.surface))
        context.stroke(disc, with: .color(DS.Colors.hairline), lineWidth: 1)
        let text = context.resolve(
            Text("\(number)").font(.system(size: diameter * 0.58, weight: .bold).monospacedDigit()).foregroundStyle(DS.Colors.textPrimary)
        )
        context.draw(text, at: center, anchor: .center)
    }

    // MARK: - Items and pointers

    private static func paintItem(_ item: ARItem, in context: inout GraphicsContext) {
        let brackets = ARGeometry.brackets(around: item.frame)
        context.stroke(brackets, with: .color(DS.Colors.underStroke), style: solid(DS.AR.itemUnder))
        context.stroke(brackets, with: .color(DS.Colors.keyline), style: solid(DS.AR.itemKeyline))
        // Each bracket arm is short, so it takes the short pattern whatever the item's size.
        context.stroke(brackets, with: .color(DS.Colors.item), style: colorStroke(DS.AR.itemStroke, lock: item.lock, size: .zero))
        if let leader = item.chip?.leader {
            var line = Path()
            line.move(to: leader.from)
            line.addLine(to: leader.to)
            context.stroke(line, with: .color(DS.Colors.keyline), style: StrokeStyle(lineWidth: DS.AR.leaderKeyline, lineCap: .round))
            context.stroke(line, with: .color(DS.Colors.item), style: StrokeStyle(lineWidth: DS.AR.leaderWidth, lineCap: .round))
            // At the chip's end, so nothing but the line itself touches the brackets.
            let dot = Path(ellipseIn: CGRect(center: leader.to, size: CGSize(width: DS.AR.leaderDot, height: DS.AR.leaderDot)))
            context.fill(dot, with: .color(DS.Colors.item))
        }
    }

    private static func paintPointer(_ pointer: ARPointer, style: Style, in context: inout GraphicsContext) {
        let disc = Path(ellipseIn: CGRect(center: pointer.center, size: ARSceneBuilder.pointerSize))
        context.fill(disc, with: .color(DS.Colors.surface))
        context.stroke(disc, with: .color(DS.Colors.hairline), lineWidth: 1)
        let wedge = ARGeometry.wedge(center: pointer.center, angle: pointer.angle)
        context.stroke(wedge, with: .color(DS.Colors.keyline), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        context.fill(wedge, with: .color(pointer.tone == .target ? DS.Colors.target : DS.Colors.item))
        if let label = pointer.chip { chip(label, style: style, in: &context) }
    }

    // MARK: - Text

    /// Solid, never glass, and the same size at any distance.
    private static func chip(_ chip: ARChip, style: Style, in context: inout GraphicsContext) {
        let shape = Path(roundedRect: chip.frame, cornerRadius: chip.frame.height / 2, style: .continuous)
        let caution = chip.tone == .caution
        context.fill(shape, with: .color(caution ? DS.Colors.caution : DS.Colors.surface))
        if !caution { context.stroke(shape, with: .color(DS.Colors.hairline), lineWidth: 1) }
        let font = DS.Fonts.label.font(for: min(style.typeSize, DS.AR.typeCap))
        let text = context.resolve(Text(chip.text).font(font).foregroundStyle(caution ? DS.Colors.ink : DS.Colors.textPrimary))
        context.draw(text, in: chip.frame.insetBy(dx: DS.AR.chipPadding.width, dy: DS.AR.chipPadding.height))
    }
}
