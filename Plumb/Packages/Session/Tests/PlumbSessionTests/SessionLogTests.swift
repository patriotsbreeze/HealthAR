import Foundation
import PlumbContracts
import Testing
@testable import PlumbSession

@Suite struct SessionLogTests {
    /// One entry of every kind the contract allows, with awkward numbers and text.
    private func fullLog() -> SessionLog {
        var log = SessionLog()
        log.append(t: 0, source: .system,
                   body: .sessionStarted(wallClock: Date(timeIntervalSinceReferenceDate: 795_190_930.123456)))
        log.append(t: 0.1 + 0.2, source: .measured, body: .lock(.estimating))
        log.append(t: 1.0 / 3.0, source: .measured,
                   body: .compression(stroke(1, at: 1.0 / 3.0, depth: 52.300000000000004, interval: nil)))
        log.append(t: 0.9, source: .measured,
                   body: .compression(stroke(2, at: 0.9, depth: 48.75, interval: 0.5666666666666667,
                                             lock: .rateOnly)))
        log.append(t: 1.2, source: .rule, body: .cue(.pushHarder))
        log.append(t: 9, source: .measured, body: .pause(start: 0.9, end: 9))
        log.append(t: 9.5, source: .model,
                   body: .toolCall(name: "look", durationS: 0.42, ok: false, summary: "Asked what is in view."))
        log.append(t: 10, source: .rule,
                   body: .blocked(what: "\"He survived\"", rule: "The record says nothing about the outcome."))
        log.append(t: 11, source: .model,
                   body: .found(label: "defibrillator", distanceM: nil, accepted: false, reason: "Too far to test."))
        log.append(t: 11.5, source: .model,
                   body: .found(label: "phone", distanceM: 1.25, accepted: true, reason: "Depth agrees."))
        log.append(t: 12, source: .said, body: .note("two lines\nand a tab\t, a slash / and an é"))
        log.append(t: 12, source: .tapped, body: .note(""))
        log.append(t: 13, source: .system, body: .sessionEnded)
        return log
    }

    @Test func idsCountUpFromOne() {
        var log = SessionLog()
        #expect(log.entries.isEmpty)
        let first = log.append(t: 0, source: .system, body: .sessionStarted(wallClock: fixtureStart))
        let second = log.append(t: 1, source: .tapped, body: .note("crew here"))
        log.append(t: 2, source: .system, body: .sessionEnded)

        #expect(first.id == 1)
        #expect(second == LogEntry(id: 2, t: 1, source: .tapped, body: .note("crew here")))
        #expect(log.entries.map(\.id) == [1, 2, 3])
        #expect(fullLog().entries.map(\.id) == Array(1...13))
    }

    @Test func timesNeverGoBackwards() {
        var log = SessionLog()
        log.append(t: 5, source: .tapped, body: .note("a"))
        let early = log.append(t: 3, source: .tapped, body: .note("b"))
        let notANumber = log.append(t: .nan, source: .tapped, body: .note("c"))
        let endless = log.append(t: .infinity, source: .tapped, body: .note("d"))
        let same = log.append(t: 5, source: .tapped, body: .note("e"))
        let later = log.append(t: 7.5, source: .tapped, body: .note("f"))

        #expect(early.t == 5)
        #expect(notANumber.t == 5)
        #expect(endless.t == 5)
        #expect(same.t == 5)
        #expect(later.t == 7.5)
        #expect(log.entries.map(\.t) == [5, 5, 5, 5, 5, 7.5])
        #expect(log.entries.map(\.id) == [1, 2, 3, 4, 5, 6])
    }

    @Test func aTimeBeforeTheSessionStartedBecomesZero() {
        var log = SessionLog()
        let entry = log.append(t: -4, source: .tapped, body: .note("early"))
        #expect(entry.t == 0)
    }

    @Test func ndjsonRoundTripsExactly() throws {
        let log = fullLog()
        let data = log.ndjson()
        let back = try SessionLog(ndjson: data)

        #expect(back.entries == log.entries)
        #expect(back == log)
        #expect(back.ndjson() == data)
    }

    @Test func ndjsonIsOneJSONObjectPerLine() throws {
        let log = fullLog()
        let text = try #require(String(data: log.ndjson(), encoding: .utf8))
        #expect(text.hasSuffix("\n"))

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == log.entries.count)
        for (line, entry) in zip(lines, log.entries) {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(object?["id"] as? Int == entry.id)
            #expect(object?["source"] as? String == entry.source.rawValue)
        }
    }

    @Test func ndjsonKeysAreAlwaysInTheSameOrder() throws {
        var log = SessionLog()
        log.append(t: 2, source: .measured, body: .compression(stroke(1, at: 2, depth: 51, interval: 0.5)))
        let line = try #require(String(data: log.ndjson(), encoding: .utf8))

        let topLevel = ["\"body\":", "\"id\":", "\"source\":", "\"t\":"]
        let inner = ["\"depthMM\":", "\"index\":", "\"intervalS\":", "\"lock\":", "\"tBottom\":", "\"tTop\":"]
        for keys in [topLevel, inner] {
            let positions = try keys.map { key in
                try #require(line.range(of: key)).lowerBound
            }
            #expect(positions == positions.sorted())
        }
        #expect(line.hasPrefix("{\"body\":"))
        #expect(log.ndjson() == log.ndjson())
    }

    @Test func numbersJSONCannotHoldStillRoundTrip() throws {
        var log = SessionLog()
        log.append(t: 1, source: .measured,
                   body: .compression(stroke(1, at: 1, depth: .infinity, interval: -.infinity)))
        log.append(t: 2, source: .model,
                   body: .found(label: "chair", distanceM: .nan, accepted: false, reason: "No depth there."))

        let back = try SessionLog(ndjson: log.ndjson())
        #expect(back.entries[0] == log.entries[0])
        guard case .found(_, let distance, _, _) = back.entries[1].body else {
            Issue.record("the second entry did not come back as a found entry")
            return
        }
        #expect(distance?.isNaN == true)
    }

    @Test func anEmptyLogIsAnEmptyFile() throws {
        #expect(SessionLog().ndjson().isEmpty)
        #expect(try SessionLog(ndjson: Data()).entries.isEmpty)
    }

    @Test func blankLinesAndWindowsLineEndingsAreTolerated() throws {
        let log = fullLog()
        let text = try #require(String(data: log.ndjson(), encoding: .utf8))
        let windows = "\n" + text.replacingOccurrences(of: "\n", with: "\r\n") + "  \n"
        #expect(try SessionLog(ndjson: Data(windows.utf8)).entries == log.entries)
    }

    @Test func aLineThatIsNotAnEntryIsReportedByNumber() {
        var log = SessionLog()
        log.append(t: 0, source: .system, body: .sessionStarted(wallClock: fixtureStart))
        var data = log.ndjson()
        data.append(Data("{\"id\":2}\n".utf8))

        #expect(throws: SessionLogError.unreadableLine(2)) {
            try SessionLog(ndjson: data)
        }
        #expect(throws: SessionLogError.unreadableLine(1)) {
            try SessionLog(ndjson: Data([0xFF, 0xFE, 0x0A]))
        }
    }

    @Test func entriesOutOfOrderAreRefused() throws {
        let log = fullLog()
        let text = try #require(String(data: log.ndjson(), encoding: .utf8))
        let lines = text.split(separator: "\n").map(String.init)

        let missingSecond = ([lines[0]] + lines[2...]).joined(separator: "\n")
        #expect(throws: SessionLogError.outOfOrder(line: 2)) {
            try SessionLog(ndjson: Data(missingSecond.utf8))
        }

        let backInTime = [
            LogEntry(id: 1, t: 5, source: .tapped, body: .note("a")),
            LogEntry(id: 2, t: 4, source: .tapped, body: .note("b")),
        ]
        let encoded = try backInTime.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        #expect(throws: SessionLogError.outOfOrder(line: 2)) {
            try SessionLog(ndjson: Data(encoded.joined(separator: "\n").utf8))
        }
    }

    @Test func aLogReadBackKeepsCountingWhereItStopped() throws {
        var back = try SessionLog(ndjson: fullLog().ndjson())
        let next = back.append(t: 1, source: .tapped, body: .note("after reload"))
        #expect(next.id == 14)
        #expect(next.t == 13)
    }
}
