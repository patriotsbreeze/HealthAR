import PlumbContracts
import PlumbSignal
import PlumbUI
import SwiftUI

/// Switches between the four screens. The rescue screen is the app; the others are reached from it.
struct RootView: View {
    let rescue: RescueController

    var body: some View {
        Group {
            switch rescue.screen {
            case .rescue:
                rescueScreen.ignoresSafeArea()
            case .working:
                workingScreen
            case .handoff:
                handoffScreen
            case .chest:
                chestScreen.ignoresSafeArea()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .animation(.easeOut(duration: 0.12), value: rescue.screen)
    }

    private var rescueScreen: some View {
        RescueScreen(panel: CoachPanel(
            command: rescue.command,
            tone: rescue.tone,
            startPrompt: rescue.startPrompt,
            model: rescue.bars,
            rate: rescue.metrics.ratePerMin,
            rateInRange: rescue.rateInRange,
            elapsedSeconds: rescue.elapsed,
            onAskChanged: { rescue.askChanged($0) },
            onFindAED: { rescue.findAED() },
            onShowWorking: { rescue.showWorking() },
            onHandOver: rescue.offersHandOver ? { rescue.handOver() } : nil,
            onCheckChest: rescue.offersChestCheck ? { rescue.checkChest() } : nil
        )) {
            rescue.feed.cameraView()
        }
    }

    @ViewBuilder private var chestScreen: some View {
        if let reading = rescue.chest {
            ChestScreen(status: reading.statusText, command: reading.commandText, context: reading.contextText,
                        trace: reading.trace.valuesMM, band: reading.trace.bandMM, bandShare: reading.trace.bandShare,
                        onStartPushing: { rescue.startPushingFromChest() },
                        onBack: { rescue.backFromChest() }) {
                rescue.feed.cameraView()
            }
        }
    }

    private var workingScreen: some View {
        let log = rescue.log
        let stats = rescue.handoff?.stats
        let lockedShare = stats?.trustedFraction ?? trustedShare(log)
        return WorkingScreen(
            timeline: WorkingTimeline(log: log, sampleRate: rescue.feed.isReplay ? "Replay" : "Camera and LiDAR",
                                      targets: rescue.targets, cueWords: { $0.spokenText }, toolWords: toolWords),
            scores: [
                WorkingScore(value: "\(rescue.metrics.count)", caption: "pushes counted"),
                WorkingScore(value: percent(lockedShare), caption: "depth trusted"),
                WorkingScore(value: rescue.feed.isReplay ? "Replay" : "Live", caption: "source"),
            ],
            failsWhen: ["Dark, loose sleeves", "Phone held, not propped", "Steep angle from above",
                        "Soft surface under the chest", "Two people in frame"],
            targets: rescue.targets,
            onBack: { rescue.backToRescue() },
            isRecording: rescue.isRecording,
            onRecordChanged: rescue.feed.canRecord ? { rescue.setRecording($0) } : nil
        ) {
            rescue.feed.depthView()
        }
    }

    /// A tool's name in plain words, with the initials people know kept in capitals: "Find AED", not "Find aed".
    private func toolWords(_ name: String) -> String {
        WorkingTimeline.plainWords(name).split(separator: " ")
            .map { ["aed", "cpr"].contains($0.lowercased()) ? $0.uppercased() : String($0) }
            .joined(separator: " ")
    }

    @ViewBuilder private var handoffScreen: some View {
        if let handoff = rescue.handoff {
            HandoffScreen(headline: handoff.headline, stats: handoff.stats, depthRange: handoff.depthRange,
                          sentences: handoff.sentences, targets: rescue.targets,
                          onReadAloud: { rescue.readAloud() },
                          onNewRescue: { rescue.newRescue() })
        }
    }

    private func trustedShare(_ log: [LogEntry]) -> Double? {
        var all = 0
        var locked = 0
        for entry in log {
            if case .compression(let stroke) = entry.body {
                all += 1
                if stroke.lock == .locked { locked += 1 }
            }
        }
        return all == 0 ? nil : Double(locked) / Double(all)
    }

    private func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}
