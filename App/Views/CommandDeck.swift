import RescueCore
import SwiftUI

/// The solid bottom deck: what to do, why, and the buttons, with the way out fixed at the bottom. The
/// band above it is all camera, so there's one seam on the screen and not two.
struct CommandDeck: View {
    let coordinator: AppCoordinator
    let onStopRequested: (RescueControl) -> Void
    let onDispatcher: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bottomInset: CGFloat = 0
    @State private var contentHeight: CGFloat = 2000
    @State private var shownHeight: CGFloat = 0
    private static let top = "deck.top"

    var body: some View {
        let awake = coordinator.definition?.kind.isAwake == true
        let camera = coordinator.leavesRoomForCamera
        let stateID = coordinator.state.stateID
        VStack(alignment: .leading, spacing: 0) {
            // Takes its own height, and on a screen too short for it, or at a large text size, it
            // scrolls and the way out doesn't. Each new step starts at the top, with the step in view.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.top)
                        // The old step fades and the new one rises in over it, in the same place, so
                        // the rows below don't jump twice.
                        ZStack(alignment: .topLeading) {
                            DeckHeader(coordinator: coordinator, compact: camera)
                                .id(stateID)
                                .transition(.step(reduceMotion: reduceMotion))
                        }
                        .animation(reduceMotion ? nil : DS.Motion.stepIn, value: stateID)
                        if let explanation = coordinator.flowExplanation {
                            // Shut on every new step, or one opened earlier would keep the band small.
                            WhyDisclosure(explanation: explanation)
                                .id(stateID)
                                .padding(.top, DS.Space.s)
                        }
                        Group {
                            if awake {
                                AwakeRows(coordinator: coordinator, compact: camera, onDispatcher: onDispatcher)
                            } else {
                                ArrestRows(coordinator: coordinator, onStopRequested: onStopRequested, onDispatcher: onDispatcher)
                            }
                        }
                        .padding(.top, camera ? DS.Space.m : DS.Space.l)
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: contentHeight)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { shownHeight = $0 }
                // A row cut at the bottom is the rest of the step, so the bar shows there is more.
                .scrollIndicatorsFlash(onAppear: true)
                .scrollIndicatorsFlash(trigger: stateID)
                .onChange(of: stateID) { proxy.scrollTo(Self.top, anchor: .top) }
            }
            if awake {
                WayOutRow(coordinator: coordinator)
                    .padding(.top, DS.Space.s)
                    .overlay(alignment: .top) {
                        // Where the step scrolls under the fixed row, a rule marks the edge, so a cut row
                        // reads as more to scroll and not as a drawing fault.
                        if shownHeight < contentHeight - 1 {
                            Rectangle().fill(DS.Colors.hairline).frame(height: 1)
                        }
                    }
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, DS.Space.deckPadding)
        .padding(.top, camera ? DS.Space.m : DS.Space.deckPadding)
        // The home indicator's strip is already clear, so the deck only needs its own margin where there isn't one.
        .padding(.bottom, bottomInset > 0 ? DS.Space.xs : DS.Space.l)
        // Exactly the width it's given. A row a fraction wider would otherwise widen the whole screen.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background { DeckSurface() }
        .onGeometryChange(for: CGFloat.self, of: \.safeAreaInsets.bottom) { bottomInset = $0 }
        .padding(.horizontal, DS.Space.deckInset)
        .sensoryFeedback(DS.Haptics.step, trigger: stateID)
    }
}

/// Inset from the edges, with corners that follow the display's where it meets them.
private struct DeckSurface: View {
    var body: some View {
        let shape = ConcentricRectangle(uniformTopCorners: .fixed(DS.Radius.deck), uniformBottomCorners: .concentric(minimum: .fixed(DS.Radius.deck)))
        shape
            .fill(DS.Colors.surface)
            .overlay(shape.stroke(DS.Colors.hairline, lineWidth: 1))
            .padding(.bottom, DS.Space.deckInset)
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

private struct DeckHeader: View {
    let coordinator: AppCoordinator
    /// A camera step's sizes, which SAFETY.md holds to so the band keeps its room.
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? DS.Space.xs : 6) {
            MetaRow(coordinator: coordinator)
            Text(CommandEmphasis.attributed(coordinator.deckCommand, terms: coordinator.commandTerms))
                .dsFont(compact ? DS.Fonts.commandCompact : DS.Fonts.command)
                .foregroundStyle(DS.Colors.textPrimary)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail = coordinator.deckDetail {
                Text(detail)
                    .dsFont(compact ? DS.Fonts.detailCompact : DS.Fonts.detail)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let prompt = coordinator.prompt {
                // Said just now, over the step's own lines.
                Label {
                    Text(prompt.text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "waveform")
                }
                .dsFont(compact ? DS.Fonts.detailCompact : DS.Fonts.prompt)
                .foregroundStyle(DS.Colors.textPrimary)
            }
            // These taps change no state, so the count is the only sign one registered.
            if coordinator.state.breathsMarked > 0 {
                Text("Breaths marked: \(coordinator.state.breathsMarked)")
                    .dsFont(DS.Fonts.value)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .contentTransition(.numericText())
            }
            if coordinator.shocksMarked > 0 {
                Text("Shocks marked: \(coordinator.shocksMarked)")
                    .dsFont(DS.Fonts.value)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .contentTransition(.numericText())
            }
            if let note = coordinator.observationNote {
                Label(note, systemImage: "ear")
                    .dsFont(DS.Fonts.label)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Step 2 of 3" only where there's a real sequence, and how long until the step moves on by itself.
private struct MetaRow: View {
    let coordinator: AppCoordinator

    var body: some View {
        let progress = coordinator.stepProgress
        if progress != nil || coordinator.definition?.timeout != nil {
            HStack(spacing: DS.Space.s) {
                if let progress { Text(progress.text) }
                Spacer(minLength: DS.Space.s)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    if let left = coordinator.secondsUntilTimeout {
                        Text("Moves on in \(Int(left.rounded(.up))) s")
                    }
                }
            }
            .dsFont(DS.Fonts.meta)
            .foregroundStyle(DS.Colors.textSecondary)
            .lineLimit(1)
        }
    }
}

/// Why the screen shows this flow, so a wrong guess can be seen and undone. The headline and who
/// chose stay in view on every step; the rest opens on a tap.
private struct WhyDisclosure: View {
    let explanation: FlowExplanation
    @State private var isOpen = false
    @State private var openHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button { isOpen.toggle() } label: {
                HStack(alignment: .center, spacing: DS.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(explanation.headline)
                            .dsFont(DS.Fonts.label)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(explanation.chooser.rawValue)
                            .dsFont(DS.Fonts.meta)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: DS.Height.control)
                .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(isOpen ? "Hides why." : "Shows why.")
            if isOpen {
                // Takes its own height, and on a screen too short for it scrolls, so the step above stays whole.
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(explanation.lines, id: \.self) { line in
                            Text(line).dsFont(DS.Fonts.body).foregroundStyle(DS.Colors.textSecondary)
                        }
                        Text(explanation.why).dsFont(DS.Fonts.body).foregroundStyle(DS.Colors.textSecondary)
                        Text(explanation.source).dsFont(DS.Fonts.caption).foregroundStyle(DS.Colors.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.m)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { openHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: min(openHeight, 160))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(DS.Motion.deck, value: isOpen)
    }
}
