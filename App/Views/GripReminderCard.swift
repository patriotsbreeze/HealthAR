import AVFoundation
import RescueVision
import SwiftUI
import UIKit

/// The CPR grip on a short silent loop, at the side of the camera's middle, as the hands go on and
/// compressions start: a reminder of how the hands go, never a step of its own. Its line says the grip
/// in words, as the spoken line does. Under Reduce Motion it is the finished grip, still.
struct GripReminderCard: View {
    static let size: CGFloat = 104
    static let caption = "Lock your grip: dominant hand on top, fingers laced tight."
    static let label = "Hand position: heel of one hand on the center of the chest, the other on top, fingers laced and lifted."

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            video
            Text(Self.caption)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .frame(width: Self.size)
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label)
    }

    private var video: some View {
        Group {
            if reduceMotion || GripReminder.video == nil {
                if let url = GripReminder.still, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else if let url = GripReminder.video {
                LoopingVideo(url: url)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1))
        .shadow(color: DS.Colors.ink.opacity(0.35), radius: 6, y: 2)
    }
}

/// A muted video that plays round and round, and leaves the app's audio alone.
private struct LoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVQueuePlayer()
        player.isMuted = true
        // Never takes the audio session, so the metronome and the spoken steps carry on untouched.
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        player.play()
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.playerLayer.player?.pause()
        uiView.looper = nil
    }

    final class PlayerView: UIView {
        var looper: AVPlayerLooper?
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
