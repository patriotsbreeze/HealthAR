import SwiftUI
import UIKit

/// "Drone preview": a continuous fly-through of the real rooms to the AED. Plays the recorded video
/// flight when `drone_video.json` has a whole one from this start, else the older frame slideshow,
/// else nothing.
struct DronePreviewButton: View {
    static let title = "Sample flight from the entrance"
    /// The AED button's mode, where fewer words do.
    static let shortTitle = "Drone from the entrance"
    static let hint = "Plays a fly-through of the building from here to the AED."

    let building: BuildingBrief
    let aedID: String
    /// The photo-located spot, else the entrance spot the drone file names.
    var start: String?
    let lengthM: Double?
    var title = Self.title
    var drone: DroneData? = DroneData.bundled
    var video: DroneVideo? = DroneVideo.bundled
    @State private var flying = false

    private var from: String? { start ?? drone?.entrancePano }

    private var videoFlight: [DroneVideo.Segment]? {
        guard let video, video.building == building.id, let from else { return nil }
        return video.flight(to: aedID, from: from)
    }

    private var frames: [DroneData.Frame]? {
        guard let drone, drone.building == building.id, let from else { return nil }
        return drone.flight(to: aedID, from: from)
    }

    var body: some View {
        if let videoFlight {
            button.fullScreenCover(isPresented: $flying) {
                let length = lengthM ?? videoFlight.reduce(0) { $0 + $1.lengthM }
                DroneVideoView(flight: videoFlight, arrivalText: DroneVideo.arrival(text: video?.targets[aedID]?.text ?? "", lengthM: length))
            }
        }
        // The old frame slideshow is no longer offered: only the continuous video flight shows.
    }

    private var button: some View {
        Button(title, systemImage: "airplane") { flying = true }
            .buttonStyle(CommandButtonStyle(kind: .secondary, height: title == Self.shortTitle ? DS.Height.arrest : DS.Height.awake))
            .accessibilityHint(Self.hint)
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

/// "Drone from where I'm standing": the video flight from the spot a photo placed the person, or the
/// closest recorded spot to it. The entrance sample stays as Drone preview.
struct DroneFromHereButton: View {
    static let title = "Drone from where I'm standing"
    /// The AED button's mode, where fewer words do.
    static let shortTitle = "Drone from here"
    static let hint = "Flies from the spot your photo matched to the AED."

    let building: BuildingBrief
    let aedID: String
    let pano: String
    let locator: LocatorData?
    var title = Self.title
    var video: DroneVideo? = DroneVideo.bundled
    @State private var flying = false

    private var plan: (flight: [DroneVideo.Segment], nearest: Bool, lengthM: Double)? {
        guard let video, video.building == building.id,
              let start = video.start(for: pano, aed: aedID, locator: locator),
              let flight = video.flight(to: aedID, from: start.pano)
        else { return nil }
        let length = locator?.routes[aedID]?[start.pano]?.lengthM ?? flight.reduce(0) { $0 + $1.lengthM }
        return (flight, start.nearest, length)
    }

    var body: some View {
        if let plan {
            Button(title, systemImage: "airplane.departure") {
                DroneVideo.log.info("drone from here: located \(pano, privacy: .public) start \(plan.flight.first?.pano ?? "-", privacy: .public) hops \(plan.flight.count) nearest \(plan.nearest)")
                flying = true
            }
                .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.awake))
                .accessibilityHint(Self.hint)
                .fullScreenCover(isPresented: $flying) {
                    DroneVideoView(
                        flight: plan.flight,
                        arrivalText: DroneVideo.arrival(text: video?.targets[aedID]?.text ?? "", lengthM: plan.lengthM),
                        note: plan.nearest ? DroneVideo.nearestNote : nil
                    )
                }
            #if DEBUG
            Text("from \(String((plan.flight.first { !$0.isIntro }?.pano ?? pano).prefix(6))) · \(plan.flight.filter { !$0.isIntro && !$0.isFinal }.count) hops\(plan.nearest ? " · nearest" : "")")
                .dsFont(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.textSecondary)
            #endif
        }
    }
}
