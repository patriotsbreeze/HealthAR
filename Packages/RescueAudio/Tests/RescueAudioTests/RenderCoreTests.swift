import Testing
@testable import RescueAudio

private func renderVoice(_ core: RenderCore, frames: Int) -> [Float] {
    var output = [Float](repeating: 9, count: frames)
    output.withUnsafeMutableBufferPointer { _ = core.renderVoice(into: $0.baseAddress!, frames: frames) }
    return output
}

private func renderClick(_ core: RenderCore, frames: Int) -> [Float] {
    var output = [Float](repeating: 9, count: frames)
    output.withUnsafeMutableBufferPointer { _ = core.renderMetronome(into: $0.baseAddress!, frames: frames) }
    return output
}

@Suite struct RenderCoreTests {
    // MARK: - Metronome

    @Test func metronomeIsSilentUntilTheCallerTurnsItOn() {
        let core = RenderCore()
        defer { core.deallocate() }
        #expect(renderClick(core, frames: 4800).allSatisfy { $0 == 0 })
    }

    @Test func firstClickLandsInTheNextBufferAfterTurningOn() {
        let core = RenderCore()
        defer { core.deallocate() }
        _ = renderClick(core, frames: 4800)
        core.setMetronome(on: true)
        #expect(renderClick(core, frames: 480)[0] != 0)
    }

    @Test func turningOffSilencesWithinOneBuffer() {
        let core = RenderCore()
        defer { core.deallocate() }
        core.setMetronome(on: true)
        _ = renderClick(core, frames: 48)
        core.setMetronome(on: false)
        #expect(renderClick(core, frames: 4800).allSatisfy { $0 == 0 })
    }

    @Test func muteKeepsTheBeatPhase() {
        let rate = RenderCore.clickSampleRate
        let reference = RenderCore()
        let muted = RenderCore()
        defer {
            reference.deallocate()
            muted.deallocate()
        }
        reference.setMetronome(on: true)
        muted.setMetronome(on: true)
        let buffer = 512
        let seconds = 10
        var referenceOutput: [Float] = []
        var mutedOutput: [Float] = []
        // Mute for a stretch in the middle, as an "AED talking" keyword does.
        for block in 0..<(rate * seconds / buffer) {
            let time = block * buffer
            muted.setMuted(time >= rate * 2 && time < rate * 7)
            referenceOutput += renderClick(reference, frames: buffer)
            mutedOutput += renderClick(muted, frames: buffer)
        }
        let muteEnd = (rate * 7 / buffer + 1) * buffer
        #expect(mutedOutput[(rate * 2 + buffer)..<(rate * 7 - buffer)].allSatisfy { $0 == 0 })
        #expect(Array(mutedOutput[muteEnd...]) == Array(referenceOutput[muteEnd...]))
        #expect(mutedOutput[muteEnd...].contains { $0 != 0 })
    }

    @Test func offThenOnStartsANewBeatButMuteDoesNot() {
        let core = RenderCore()
        defer { core.deallocate() }
        core.setMetronome(on: true)
        _ = renderClick(core, frames: 20_000)
        core.setMuted(true)
        _ = renderClick(core, frames: 100)
        core.setMuted(false)
        // Partway through a beat, not at a new first click.
        #expect(renderClick(core, frames: 1)[0] == 0)

        core.setMetronome(on: false)
        _ = renderClick(core, frames: 100)
        core.setMetronome(on: true)
        #expect(renderClick(core, frames: 1)[0] != 0)
    }

    @Test func heartbeatCountsRenderCallsWhetherOnOrOff() {
        let core = RenderCore()
        defer { core.deallocate() }
        _ = renderClick(core, frames: 10)
        core.setMetronome(on: true)
        _ = renderClick(core, frames: 10)
        #expect(core.renderCallCount == 2)
    }

    // MARK: - Voice

    @Test func localPhraseWinsOverReadAloudWhichWinsOverModel() {
        let core = RenderCore()
        defer { core.deallocate() }
        core.modelRing.push([3, 3, 3, 3])
        core.readAloudRing.push([2, 2])
        core.phraseRing.push([1, 1])
        #expect(renderVoice(core, frames: 3) == [1, 1, 2])
        #expect(renderVoice(core, frames: 3) == [2, 3, 3])
    }

    @Test func aPhraseArrivingMidStreamTakesOverOnTheNextBuffer() {
        let core = RenderCore()
        defer { core.deallocate() }
        core.modelRing.push([3, 3, 3, 3, 3, 3])
        #expect(renderVoice(core, frames: 2) == [3, 3])
        core.modelRing.flush()
        core.phraseRing.push([1, 1])
        #expect(renderVoice(core, frames: 4) == [1, 1, 0, 0])
    }

    @Test func flushedModelAudioIsNeverHeard() {
        let core = RenderCore()
        defer { core.deallocate() }
        core.modelRing.push([3, 3, 3])
        core.modelRing.flush()
        #expect(renderVoice(core, frames: 3) == [0, 0, 0])
    }

    @Test func emptyVoiceRendersSilence() {
        let core = RenderCore()
        defer { core.deallocate() }
        var output = [Float](repeating: 9, count: 4)
        let silent = output.withUnsafeMutableBufferPointer { core.renderVoice(into: $0.baseAddress!, frames: 4) }
        #expect(silent)
        #expect(output == [0, 0, 0, 0])
    }

    @Test func muteHoldsPhrasesInsteadOfLosingThem() {
        let core = RenderCore()
        defer { core.deallocate() }
        core.phraseRing.push([1, 2, 3])
        #expect(renderVoice(core, frames: 1) == [1])
        core.setMuted(true)
        #expect(renderVoice(core, frames: 2) == [0, 0])
        #expect(core.phraseRing.totalRead == 1)
        core.setMuted(false)
        #expect(renderVoice(core, frames: 2) == [2, 3])
    }

    @Test func flushDuringMuteStillApplies() {
        let core = RenderCore()
        defer { core.deallocate() }
        core.modelRing.push([3, 3])
        core.setMuted(true)
        core.modelRing.flush()
        _ = renderVoice(core, frames: 2)
        core.setMuted(false)
        #expect(renderVoice(core, frames: 2) == [0, 0])
    }

    // MARK: - Mic

    @Test func micCaptureDropsWhenFullAndDoesNotBlock() {
        let core = RenderCore()
        defer { core.deallocate() }
        let frames = core.micRing.capacity + 100
        let input = [Float](repeating: 0.5, count: frames)
        input.withUnsafeBufferPointer { core.captureMic($0.baseAddress!, frames: frames) }
        #expect(core.micRing.totalWritten == core.micRing.capacity)
    }
}
