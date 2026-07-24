import Foundation

/// Parses a unified diff (as produced by `gh pr diff`) into rows suitable for a
/// side-by-side (left = original, right = changed) view. Pure and testable.
public enum DiffParser {
    public struct Cell: Sendable, Equatable {
        public let number: Int?
        public let text: String
        public init(number: Int?, text: String) { self.number = number; self.text = text }
    }

    public enum RowKind: Sendable, Equatable { case fileHeader, hunkHeader, line }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: Int
        public let kind: RowKind
        public let header: String?     // for fileHeader / hunkHeader
        public let left: Cell?         // original side (deletion or context)
        public let right: Cell?        // changed side (addition or context)
        public let isChange: Bool      // true for additions/deletions, false for context
    }

    public static func parse(_ diff: String) -> [Row] {
        var rows: [Row] = []
        var id = 0
        func emit(_ kind: RowKind, header: String? = nil, left: Cell? = nil, right: Cell? = nil, isChange: Bool = false) {
            rows.append(Row(id: id, kind: kind, header: header, left: left, right: right, isChange: isChange))
            id += 1
        }

        var oldLine = 0
        var newLine = 0
        var pendingDel: [Cell] = []
        var pendingAdd: [Cell] = []

        func flush() {
            let count = max(pendingDel.count, pendingAdd.count)
            for i in 0..<count {
                emit(.line,
                     left: i < pendingDel.count ? pendingDel[i] : nil,
                     right: i < pendingAdd.count ? pendingAdd[i] : nil,
                     isChange: true)
            }
            pendingDel.removeAll(keepingCapacity: true)
            pendingAdd.removeAll(keepingCapacity: true)
        }

        for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.hasPrefix("diff --git") {
                flush()
                // Prefer the "b/<path>" target as the file label.
                let path = rawLine.components(separatedBy: " b/").last ?? rawLine
                emit(.fileHeader, header: path)
            } else if rawLine.hasPrefix("@@") {
                flush()
                let (o, n) = parseHunkStarts(rawLine)
                oldLine = o
                newLine = n
                emit(.hunkHeader, header: rawLine)
            } else if rawLine.hasPrefix("+++") || rawLine.hasPrefix("---")
                        || rawLine.hasPrefix("index ") || rawLine.hasPrefix("new file")
                        || rawLine.hasPrefix("deleted file") || rawLine.hasPrefix("rename ")
                        || rawLine.hasPrefix("similarity ") || rawLine.hasPrefix("old mode")
                        || rawLine.hasPrefix("new mode") || rawLine.hasPrefix("\\ No newline") {
                continue // metadata — not shown as content
            } else if rawLine.hasPrefix("+") {
                pendingAdd.append(Cell(number: newLine, text: String(rawLine.dropFirst())))
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                pendingDel.append(Cell(number: oldLine, text: String(rawLine.dropFirst())))
                oldLine += 1
            } else {
                // context line (leading space) or blank line between hunks
                flush()
                let text = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
                if rawLine.isEmpty && rows.last?.kind != .line { continue }
                emit(.line,
                     left: Cell(number: oldLine, text: text),
                     right: Cell(number: newLine, text: text),
                     isChange: false)
                oldLine += 1
                newLine += 1
            }
        }
        flush()
        return rows
    }

    /// Extracts old/new start line numbers from a hunk header `@@ -a,b +c,d @@`.
    static func parseHunkStarts(_ header: String) -> (old: Int, new: Int) {
        var old = 1, new = 1
        let parts = header.split(separator: " ")
        for part in parts {
            if part.hasPrefix("-"), let v = Int(part.dropFirst().split(separator: ",").first ?? "") { old = v }
            if part.hasPrefix("+"), let v = Int(part.dropFirst().split(separator: ",").first ?? "") { new = v }
        }
        return (old, new)
    }
}
