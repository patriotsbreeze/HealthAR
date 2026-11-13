import Foundation
import PlumbContracts

/// Turns log entries into lines of JSON and back.
enum LogLineCodec {
    private static let lineBreak = UInt8(ascii: "\n")
    // JSON has no way to write these, so they travel as words and come back as the same numbers.
    private static let infinityWord = "inf"
    private static let negativeInfinityWord = "-inf"
    private static let notANumberWord = "nan"

    static func data(for entries: [LogEntry]) -> Data {
        let encoder = JSONEncoder()
        // Sorted keys keep the file byte-for-byte the same for the same log.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: infinityWord, negativeInfinity: negativeInfinityWord, nan: notANumberWord)
        var data = Data()
        for entry in entries {
            data.append(line(for: entry, using: encoder))
            data.append(lineBreak)
        }
        return data
    }

    static func entries(from data: Data) throws -> [LogEntry] {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: infinityWord, negativeInfinity: negativeInfinityWord, nan: notANumberWord)
        var entries: [LogEntry] = []
        for (index, line) in data.split(separator: lineBreak, omittingEmptySubsequences: false).enumerated() {
            if line.allSatisfy(isBlank) { continue }
            let lineNumber = index + 1
            guard let entry = try? decoder.decode(LogEntry.self, from: Data(line)) else {
                throw SessionLogError.unreadableLine(lineNumber)
            }
            guard entry.id == entries.count + 1, entry.t >= (entries.last?.t ?? 0) else {
                throw SessionLogError.outOfOrder(line: lineNumber)
            }
            entries.append(entry)
        }
        return entries
    }

    private static func line(for entry: LogEntry, using encoder: JSONEncoder) -> Data {
        if let line = try? encoder.encode(entry) { return line }
        // An entry holds only numbers, text and dates, and numbers JSON cannot hold are written as
        // words, so encoding is not expected to fail. If it ever does, the gap is written as a
        // line that will not read back as an entry, so the loss is reported instead of hidden.
        return Data("{\"lostEntry\":\(entry.id)}".utf8)
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
    }
}
