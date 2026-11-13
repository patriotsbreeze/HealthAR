import Foundation

/// A plain table of text: numbers flush right, words flush left, two spaces between columns.
struct TextTable {
    var header: [String]
    /// Columns of words rather than numbers. The first column, the row names, always is one.
    var wordColumns: Set<Int>
    var rows: [[String]] = []

    init(_ header: [String], wordColumns: Set<Int> = []) {
        self.header = header
        self.wordColumns = wordColumns.union([0])
    }

    mutating func add(_ row: [String]) {
        rows.append(row)
    }

    var text: String {
        let all = [header] + rows
        let columns = all.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            all.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
        }
        return all.map { row in
            (0..<columns).map { column in
                let cell = column < row.count ? row[column] : ""
                let pad = String(repeating: " ", count: widths[column] - cell.count)
                return wordColumns.contains(column) ? cell + pad : pad + cell
            }
            .joined(separator: "  ")
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        .joined(separator: "\n")
    }
}

/// How numbers are written in the report: a fixed number of places, a dash for none.
enum Figure {
    static func fixed(_ value: Double?, _ places: Int) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.\(places)f", value)
    }

    /// With its sign always shown, for errors. Anything that rounds to nothing is shown as +0, never -0.
    static func signed(_ value: Double?, _ places: Int) -> String {
        guard let value, value.isFinite else { return "-" }
        let scale = pow(10, Double(places))
        let shown = (value * scale).rounded() / scale
        return String(format: "%+.\(places)f", shown == 0 ? 0 : shown)
    }

    static func percent(_ share: Double?) -> String {
        guard let share, share.isFinite else { return "-" }
        return String(format: "%.0f%%", share * 100)
    }
}
