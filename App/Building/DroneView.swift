import SwiftUI
import UIKit

/// "Drone preview": a quick fly-through of the real rooms to the AED, played from recorded frames.
/// Shown only where the drone file has a flight for that AED from that start.
struct DronePreviewButton: View {
    static let title = "Drone preview"
    static let hint = "Plays a fly-through of the building from here to the AED, from the survey's own pictures."

    let building: BuildingBrief
    let aedID: String
    /// The photo-located spot, else the entrance spot the drone file names.
    var start: String?
    let lengthM: Double?
    var drone: DroneData? = DroneData.bundled
    @State private var flying = false

    private var flight: [DroneData.Frame]? {
        guard let drone, drone.building == building.id, let from = start ?? drone.entrancePano else { return nil }
        return drone.flight(to: aedID, from: from)
    }

    var body: some View {
        if let flight, let drone, let target = drone.targets[aedID] {
            Button(Self.title, systemImage: "airplane") { flying = true }
                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.awake))
                .accessibilityHint(Self.hint)
                .fullScreenCover(isPresented: $flying) {
                    DronePlayer(
                        frames: flight,
                        arrival: DroneData.arrival(target, aed: building.aeds.first { $0.id == aedID }, lengthM: lengthM)
                    )
                }
        }
    }
}

/// Each frame crossfades into the next with a slow push forward, so it reads as flying. Reduce Motion
/// keeps the crossfade and drops the push.
private struct DronePlayer: View {
    static let frameSeconds = 0.7
    static let reverseSeconds = 0.25
    static let push: CGFloat = 1.15

    let frames: [DroneData.Frame]
    let arrival: (title: String, detail: String?)
    @State private var index = 0
    @State private var arrived = false
    @State private var run = 0
    @State private var rewinding = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            DroneFrame(frame: frames[index], seconds: Self.frameSeconds, push: reduceMotion ? 1 : Self.push)
                .id(index)
                .transition(.opacity)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                SimulationStrip()
                Spacer()
                panel
                    .padding(.horizontal, DS.Space.deckInset)
                    .padding(.bottom, DS.Glass.deckGap)
            }
        }
        .task(id: run) { await fly() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if arrived {
                Text(arrival.title)
                    .dsFont(DS.Fonts.detail)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = arrival.detail {
                    Text(detail).dsFont(DS.Fonts.label).foregroundStyle(DS.Colors.textSecondary)
                }
            } else {
                Text(DroneData.caption(frames[index]))
                    .dsFont(DS.Fonts.prompt)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            ProgressView(value: Double(index + 1), total: Double(frames.count))
                .tint(DS.Colors.textPrimary)
                .accessibilityLabel("Stop \(index + 1) of \(frames.count)")
            HStack(spacing: DS.Space.betweenButtons) {
                Button("Back to start") { Task { await rewind() } }
                    .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.control, font: DS.Fonts.buttonCompact))
                    .disabled(index == 0 || rewinding)
                Button("Fly again") {
                    arrived = false
                    index = 0
                    run += 1
                }
                .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.control, font: DS.Fonts.buttonCompact))
                Button("Close") { dismiss() }
                    .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.control, font: DS.Fonts.buttonCompact))
            }
        }
        .foregroundStyle(DS.Colors.textPrimary)
        .padding(DS.Space.deckPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: DS.Glass.deckRadius, style: .continuous), tint: DS.Glass.deckTint)
    }

    private func fly() async {
        if rewinding { return }
        while index < frames.count - 1 {
            try? await Task.sleep(for: .seconds(Self.frameSeconds))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.35)) { index += 1 }
        }
        try? await Task.sleep(for: .seconds(Self.frameSeconds))
        if Task.isCancelled { return }
        withAnimation(DS.Motion.alert) { arrived = true }
    }

    /// The same frames backwards, three times as fast.
    private func rewind() async {
        rewinding = true
        run += 1 // cancels the flight; Fly again starts a new one
        arrived = false
        while index > 0 {
            withAnimation(.easeInOut(duration: 0.15)) { index -= 1 }
            try? await Task.sleep(for: .seconds(Self.reverseSeconds))
        }
        rewinding = false
    }
}

/// One frame, filling the screen from its centre, which is the way the walk goes.
private struct DroneFrame: View {
    let frame: DroneData.Frame
    let seconds: Double
    let push: CGFloat
    @State private var scale: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            if let url = DroneData.imageURL(frame.img), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale)
                    .clipped()
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            guard push > 1 else { return }
            withAnimation(.linear(duration: seconds * 1.5)) { scale = push }
        }
    }
}
