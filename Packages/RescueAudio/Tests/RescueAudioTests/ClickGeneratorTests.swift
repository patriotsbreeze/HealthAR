import Testing
import Foundation
@testable import RescueAudio

/// Finds each click as the first non-zero sample after a long silence.
private func clickStarts(sampleRate: Int, seconds: Int, bufferSize: Int) -> [Int] {
    var generator = ClickGenerator(sampleRate: sampleRate)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    let total = sampleRate * seconds
    let minimumSilence = sampleRate / 100
    var starts: [Int] = []
    var zeros = minimumSilence
    var position = 0
    while position < total {
        let count = min(bufferSize, total - position)
        generator.render(into: buffer, frameCount: count)
        for index in 0..<count {
            if buffer[index] == 0 {
                zeros += 1
            } else {
                if zeros >= minimumSilence { starts.append(position + index) }
                zeros = 0
            }
        }
        position += count
    }
    return starts
}

@Suite struct ClickGeneratorTests {
    @Test func intervalIs545Point45Milliseconds() {
        #expect(abs(ClickGenerator.beatInterval * 1000 - 545.4545) < 0.001)
    }

    @Test(arguments: [44_100, 48_000])
    func onsetsStayOnTheIdealGridForFiveMinutes(sampleRate: Int) {
        // An odd buffer size so buffer edges fall at every position relative to the beat.
        let starts = clickStarts(sampleRate: sampleRate, seconds: 300, bufferSize: 479)
        let beats = stride(from: 0, to: starts.count, by: 2).map { starts[$0] }
        let softClicks = stride(from: 1, to: starts.count, by: 2).map { starts[$0] }

        #expect(beats.count == 550)
        let ideal = 60.0 * Double(sampleRate) / 110
        for (index, onset) in beats.enumerated() {
            #expect(abs(Double(onset) - Double(index) * ideal) <= 0.5)
        }
        for (first, second) in zip(beats, beats.dropFirst()) {
            #expect(abs(Double(second - first) - ideal) <= 1)
        }
        let averageMilliseconds = Double(beats[549] - beats[0]) / 549 / Double(sampleRate) * 1000
        #expect(abs(averageMilliseconds - 545.4545) < 0.001)

        let softDelay = Int(ClickGenerator.softClickDelay * Double(sampleRate))
        for (beat, soft) in zip(beats, softClicks) {
            #expect(soft - beat == softDelay)
        }
    }

    @Test func driftFreeFarBeyondARealRescue() {
        let generator = ClickGenerator(sampleRate: 48_000)
        // A full day of beats: still the exact rounded grid position.
        #expect(generator.beatOnset(158_400) == 158_400 * 2_880_000 / 110)
    }

    @Test func outputDoesNotDependOnBufferSize() {
        let total = 48_000
        var whole = ClickGenerator(sampleRate: 48_000)
        var pieces = ClickGenerator(sampleRate: 48_000)
        let wholeBuffer = UnsafeMutablePointer<Float>.allocate(capacity: total)
        let pieceBuffer = UnsafeMutablePointer<Float>.allocate(capacity: total)
        defer {
            wholeBuffer.deallocate()
            pieceBuffer.deallocate()
        }
        whole.render(into: wholeBuffer, frameCount: total)
        var position = 0
        var size = 1
        while position < total {
            let count = min(size, total - position)
            pieces.render(into: pieceBuffer + position, frameCount: count)
            position += count
            size = size % 977 + 13
        }
        for index in 0..<total {
            #expect(wholeBuffer[index] == pieceBuffer[index])
        }
    }

    @Test func secondClickIsSofterAndNothingClips() {
        let sampleRate = 48_000
        var generator = ClickGenerator(sampleRate: sampleRate)
        let count = sampleRate / 2
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { buffer.deallocate() }
        generator.render(into: buffer, frameCount: count)

        let softStart = Int(ClickGenerator.softClickDelay * Double(sampleRate))
        let firstPeak = (0..<softStart).map { abs(buffer[$0]) }.max() ?? 0
        let secondPeak = (softStart..<count).map { abs(buffer[$0]) }.max() ?? 0
        #expect(firstPeak > 0.1)
        #expect(firstPeak <= 1)
        #expect(secondPeak > 0)
        #expect(abs(Double(secondPeak / firstPeak) - ClickGenerator.softClickGain) < 0.01)
    }

    @Test func clickEnergyIsInTheMidrange() {
        let sampleRate = 48_000
        var generator = ClickGenerator(sampleRate: sampleRate)
        let count = sampleRate * 25 / 1000
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { buffer.deallocate() }
        generator.render(into: buffer, frameCount: count)

        func magnitude(atHertz hertz: Double) -> Double {
            var real = 0.0
            var imaginary = 0.0
            for index in 0..<count {
                let phase = 2 * Double.pi * hertz * Double(index) / Double(sampleRate)
                real += Double(buffer[index]) * cos(phase)
                imaginary += Double(buffer[index]) * sin(phase)
            }
            return (real * real + imaginary * imaginary).squareRoot()
        }
        let midrange = magnitude(atHertz: 1400)
        #expect(midrange > magnitude(atHertz: 100) * 5)
        #expect(midrange > magnitude(atHertz: 8000) * 5)
    }

    @Test func resetStartsAClickImmediately() {
        var generator = ClickGenerator(sampleRate: 48_000)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 10_000)
        defer { buffer.deallocate() }
        generator.render(into: buffer, frameCount: 10_000)
        generator.reset()
        #expect(generator.sampleCounter == 0)
        generator.render(into: buffer, frameCount: 1)
        #expect(buffer[0] != 0)
    }
}
