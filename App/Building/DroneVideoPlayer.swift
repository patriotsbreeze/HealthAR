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

    func play() {
        arrived = false
        player.play()
    }

    func flyAgain() {
        arrived = false
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.player.play() }
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
    @State private var model: DroneFlightPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(flight: [DroneVideo.Segment], arrivalText: String) {
        self.flight = flight
        self.arrivalText = arrivalText
        _model = State(initialValue: DroneFlightPlayer(segments: flight))
    }

    var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            PlayerLayerView(player: model.player).ignoresSafeArea()
            TimelineView(.animation(paused: !model.ready)) { _ in
                hud(time: max(0, model.player.currentTime().seconds))
            }
            if model.arrived {
                VStack {
                    Spacer()
                    arrivalCard
                        .padding(.horizontal, DS.Space.deckInset)
                        .padding(.bottom, DS.Glass.deckGap)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
        }
        .animation(DS.Motion.deck, value: model.arrived)
        .sensoryFeedback(.impact(weight: .light), trigger: model.arrived) { _, new in new }
        .task {
            await model.prepare(reduceMotion: reduceMotion)
            model.play()
        }
        .onDisappear { model.stop() }
        .statusBarHidden()
    }

    // MARK: - HUD

    private func hud(time: Double) -> some View {
        let shown = model.segmentsShown
        let index = DroneVideo.index(at: time, starts: model.starts)
        let remaining = DroneVideo.remaining(at: time, segments: shown, starts: model.starts, durations: model.durations)
        let progress = model.total > 0 ? min(1, time / model.total) : 0
        let caption = shown.indices.contains(index) ? DroneVideo.caption(shown[index]) : ""

        return ZStack {
            Reticle().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Circle().fill(DS.Colors.critical).frame(width: 6, height: 6)
                        Text("DRONE · LIVE ROUTE")
                    }
                    .dsFont(DS.Fonts.badge)
                    .fontDesign(.monospaced)
                    .tracking(1.2)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: DS.Height.control, height: DS.Height.control)
                    }
                    .accessibilityLabel("Close")
                }
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text("AED")
                        .dsFont(DS.Fonts.meta)
                        .foregroundStyle(DS.Colors.ok)
                    Text("\(Int(remaining.rounded())) m")
                        .dsFont(DS.Fonts.title)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                }
                .fontDesign(.monospaced)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("AED, \(Int(remaining.rounded())) metres")
                Spacer()
                if !caption.isEmpty {
                    Text(caption)
                        .dsFont(DS.Fonts.badge)
                        .fontDesign(.monospaced)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassSurface(Capsule(style: .continuous))
                        .id(caption)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: caption)
                }
                GeometryReader { geometry in
                    Capsule().fill(Color.white.opacity(0.18))
                        .overlay(alignment: .leading) {
                            Capsule().fill(DS.Colors.textPrimary).frame(width: geometry.size.width * progress)
                        }
                }
                .frame(height: 2)
                .opacity(model.arrived ? 0 : 1)
            }
            .foregroundStyle(DS.Colors.textPrimary)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.l)
        }
    }

    private var arrivalCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(arrivalText)
                .dsFont(DS.Fonts.prompt)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.betweenButtons) {
                Button("Back to start") { model.backToStart() }
                    .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.control, font: DS.Fonts.buttonCompact, lineLimit: 1))
                Button("Fly again") { model.flyAgain() }
                    .buttonStyle(CommandButtonStyle(kind: .secondary, height: DS.Height.control, font: DS.Fonts.buttonCompact, lineLimit: 1))
                Button("Close") { dismiss() }
                    .buttonStyle(CommandButtonStyle(kind: .primary, height: DS.Height.control, font: DS.Fonts.buttonCompact, lineLimit: 1))
            }
        }
        .foregroundStyle(DS.Colors.textPrimary)
        .padding(DS.Space.deckPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: DS.Glass.deckRadius, style: .continuous), tint: DS.Glass.deckTint)
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
