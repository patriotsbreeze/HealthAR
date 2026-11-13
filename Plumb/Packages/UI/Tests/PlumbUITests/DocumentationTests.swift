import Foundation
import Testing

/// Reads the package's own sources and checks the rule that every public symbol says what it means.
@Suite struct DocumentationTests {
    /// Packages/UI/Sources/PlumbUI, found from this file.
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/PlumbUI", isDirectory: true)

    private func swiftFiles() throws -> [URL] {
        let walker = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func everyPublicSymbolHasADocComment() throws {
        var undocumented: [String] = []
        let files = try swiftFiles()
        #expect(files.count > 20)
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            for (index, line) in lines.enumerated() where line.hasPrefix("public ") {
                // Attributes such as @MainActor sit between a doc comment and its declaration.
                var above = index - 1
                while above >= 0, lines[above].hasPrefix("@") { above -= 1 }
                if above < 0 || !lines[above].hasPrefix("///") {
                    undocumented.append("\(file.lastPathComponent):\(index + 1): \(line)")
                }
            }
        }
        #expect(undocumented.isEmpty, "\(undocumented.joined(separator: "\n"))")
    }

    /// A case of a public enum is public too, though the word is not written on it.
    @Test func everyCaseOfAPublicEnumHasADocComment() throws {
        var undocumented: [String] = []
        for file in try swiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            var enumIndent: Int?
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let indent = raw.prefix { $0 == " " }.count
                if line.hasPrefix("public enum ") {
                    enumIndent = indent
                } else if let open = enumIndent, line == "}", indent == open {
                    enumIndent = nil
                } else if let open = enumIndent, indent == open + 4, line.hasPrefix("case "),
                          index == 0 || !lines[index - 1].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
                    undocumented.append("\(file.lastPathComponent):\(index + 1): \(line)")
                }
            }
        }
        #expect(undocumented.isEmpty, "\(undocumented.joined(separator: "\n"))")
    }

    /// Tunable numbers live in Theme.Metrics. A line limit is one of them, so no view may write its own.
    @Test func noViewWritesItsOwnLineLimit() throws {
        var literals: [String] = []
        for file in try swiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard let range = line.range(of: ".lineLimit(") else { continue }
                // One line is a statement about the design, not a number to tune.
                let argument = line[range.upperBound...].prefix { $0 != ")" }
                if Int(argument) != nil, argument != "1" {
                    literals.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(literals.isEmpty, "\(literals.joined(separator: "\n"))")
    }
}
