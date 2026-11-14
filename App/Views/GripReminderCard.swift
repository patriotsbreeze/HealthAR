import AVFoundation
import RescueVision
import SwiftUI
import UIKit

/// The CPR grip on a short silent loop, small in a corner, as compressions start: a reminder of how
/// the hands go, never a step of its own. Under Reduce Motion it is the finished grip, still.
struct GripReminderCard: View {
    static let size: CGFloat = 104
    static let label = "Hand position: heel of one hand on the center of the chest, the other on top, fingers laced and lifted."

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label)
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
