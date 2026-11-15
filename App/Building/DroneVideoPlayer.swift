import AVFoundation
import SwiftUI
import UIKit

/// The flight as one gapless video: every hop's clip laid back to back in a composition, played full
/// screen under a thin drone-style HUD. Built before it shows, so it starts at once.
@MainActor
@Observable
final class DroneFlightPlayer {
    let segments: [DroneVideo.Segment]
    let player = AVPlayer()
    private(set) var ready = false
    private(set) var arrived = false
    /// Each segment's start and length, as the composition laid them out.
    private(set) var starts: [Double] = []
    private(set) var durations: [Double] = []
    var total: Double { (starts.last ?? 0) + (durations.last ?? 0) }

    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?

    init(segments: [DroneVideo.Segment]) {
        self.segments = segments
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    /// Reduce Motion leaves out the final push-in and holds the last hop's frame.
    func prepare(reduceMotion: Bool) async {
        guard !ready else { return }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        var cursor = CMTime.zero
        var starts: [Double] = []
        var durations: [Double] = []
        for segment in segments where !(reduceMotion && segment.isFinal) {
            guard let url = DroneVideo.url(segment.file) else { break }
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .video).first,
                  let range = try? await source.load(.timeRange)
            else { break }
            if starts.isEmpty, let transform = try? await source.load(.preferredTransform) {
                track.preferredTransform = transform
            }
            do { try track.insertTimeRange(range, of: source, at: cursor) } catch { break }
            starts.append(cursor.seconds)
            durations.append(range.duration.seconds)
            cursor = cursor + range.duration
        }
        guard !starts.isEmpty else { return }
        self.starts = starts
        self.durations = durations
        let item = AVPlayerItem(asset: composition)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.arrived = true }
        }
        ready = true
    }

    /// A touch quicker than recorded. The HUD reads the player's clock, so it stays right at any rate.
    static let rate: Float = 1.25

    func play() {
        arrived = false
        player.playImmediately(atRate: Self.rate)
    }

    func flyAgain() {
        arrived = false
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.player.playImmediately(atRate: DroneFlightPlayer.rate) }
        }
    }

    /// Backwards at double speed where the item allows it, otherwise straight back to the start.
    func backToStart() {
        arrived = false
        guard let item = player.currentItem else { return }
        if item.canPlayReverse {
            player.rate = -2
            Task { @MainActor [weak self] in
                while let self, self.player.rate < 0, self.player.currentTime().seconds > 0.05 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self?.player.pause()
                _ = await self?.player.seek(to: .zero)
            }
        } else {
            player.pause()
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func stop() {
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    var segmentsShown: [DroneVideo.Segment] {
        Array(segments.prefix(starts.count))
    }
}

struct DroneVideoView: View {
    let flight: [DroneVideo.Segment]
    let arrivalText: String
    /// Shown while flying in place of "Flying to the AED", e.g. when starting from a nearby spot.
    var note: String?
    @State private var model: DroneFlightPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(flight: [DroneVideo.Segment], arrivalText: String, note: String? = nil) {
        self.flight = flight
        self.arrivalText = arrivalText
        self.note = note
        _model = State(initialValue: DroneFlightPlayer(segments: flight))
    }

    var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            PlayerLayerView(player: model.player).ignoresSafeArea()
            // A soft shade top and bottom, so the glass reads over a bright hallway.
            LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            TimelineView(.animation(paused: !model.ready)) { _ in
                hud(time: max(0, model.player.currentTime().seconds))
            }
        }
        .animation(DS.Motion.deck, value: model.arrived)
        .sensoryFeedback(DS.Haptics.holdBegan, trigger: model.arrived) { _, new in new }
        .task {
            await model.prepare(reduceMotion: reduceMotion)
            model.play()
        }
        .onDisappear { model.stop() }
    }

    // MARK: - HUD: the team's rail on top, the deck at the bottom

    private func hud(time: Double) -> some View {
        let shown = model.segmentsShown
        let index = DroneVideo.index(at: time, starts: model.starts)
        let remaining = Int(DroneVideo.remaining(at: time, segments: shown, starts: model.starts, durations: model.durations).rounded())
        let progress = model.total > 0 ? min(1, time / model.total) : 0
        let caption = shown.indices.contains(index) ? DroneVideo.caption(shown[index]) : ""

        return ZStack {
            Reticle().opacity(model.arrived ? 0 : 1).accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.s) {
                    Pill { StatusDot(text: "Drone preview", color: DS.Colors.critical) }
                    Pill {
                        Text("AED")
                            .dsFont(DS.Fonts.meta)
                            .foregroundStyle(DS.Colors.ok)
                        Text("\(remaining) m")
                            .dsFont(DS.Fonts.value)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("AED, \(remaining) metres")
                    Spacer(minLength: 0)
                    FloatingGlassButton(systemImage: "xmark", label: "Close") { dismiss() }
                }
                .frame(minHeight: DS.Height.rail)
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, DS.Space.xs)
                Spacer()
                deck(caption: caption, progress: progress)
            }
        }
    }

    /// The deck: where the flight is on the way, then the arrival and what to do next.
    private func deck(caption: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if model.arrived {
                Text(arrivalText)
                    .dsFont(DS.Fonts.prompt)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                HStack(spacing: DS.Space.s) {
                    Button("Back to start", systemImage: "backward.fill") { model.backToStart() }
                        .buttonStyle(DeckCapsuleButtonStyle())
                    Button("Fly again", systemImage: "arrow.clockwise") { model.flyAgain() }
                        .buttonStyle(DeckCapsuleButtonStyle())
                }
                Button("Close") { dismiss() }
                    .buttonStyle(DeckCapsuleButtonStyle(prominent: true))
            } else {
                HStack(spacing: DS.Space.s) {
                    Text(caption)
                        .dsFont(DS.Fonts.label)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .id(caption)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: caption)
                    Spacer(minLength: 0)
                    Text(note ?? "Flying to the AED")
                        .dsFont(DS.Fonts.meta)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                GeometryReader { geometry in
                    Capsule().fill(DS.Glass.fill)
                        .overlay(alignment: .leading) {
                            Capsule().fill(DS.Colors.textPrimary).frame(width: geometry.size.width * progress)
                        }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .buildingDeck()
    }
}

/// A faint crosshair in the centre, as on a drone feed.
private struct Reticle: View {
    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            var path = Path()
            for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                path.move(to: CGPoint(x: centre.x + dx * 10, y: centre.y + dy * 10))
                path.addLine(to: CGPoint(x: centre.x + dx * 22, y: centre.y + dy * 22))
            }
            path.addEllipse(in: CGRect(x: centre.x - 2, y: centre.y - 2, width: 4, height: 4))
            context.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// The video, filling the screen from its centre.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
