//
//  MarkdownTable.swift
//  MarkdownEngine
//
//  Value model of a GFM pipe table: parse from source, edit structurally,
//  serialize back. The interactive table grid edits a `MarkdownTable` and
//  writes `markdown()` over the table's source range, so the document
//  always stays a plain GFM table.
//
//  Cells hold their inline markdown with pipe escapes removed (`a \| b` is
//  stored as `a | b`); `markdown()` re-escapes them.
//
//  Column widths live in an attribute line directly after the table,
//  `{cols="30%,auto,120"}` (the `{…}` syntax of `MarkdownAttributes`):
//  `auto` sizes to the content, a number is points, `%` is a share of the
//  width available to the table. Other entries on that line are kept.
//

import CoreGraphics
import Foundation

public struct MarkdownTable: Equatable, Sendable {

    public enum Alignment: Equatable, Sendable {
        /// `---` — no explicit alignment (renders left).
        case none
        /// `:---`
        case left
        /// `:---:`
        case center
        /// `---:`
        case right
    }

    /// Header cells; always `columnCount` long.
    public var header: [String]
    /// One entry per column.
    public var alignments: [Alignment]
    /// Body rows; each always `columnCount` long.
    public var rows: [[String]]
    /// One entry per column; all `.auto` unless the table has a `cols` attribute.
    public var columnWidths: [ColumnWidth]
    /// Entries of the trailing attribute line other than `cols`, kept as written.
    public var otherAttributes: [MarkdownAttributes.Item]

    /// How wide a column is drawn.
    public enum ColumnWidth: Equatable, Sendable {
        /// Fits the widest cell.
        case auto
        /// A fixed width in points (the whole column box, padding included).
        case points(CGFloat)
        /// A share (0–100) of the width available to the table.
        case percent(CGFloat)

        /// `auto`, `120`, `30%`.
        public init?(_ text: String) {
            let t = text.trimmingCharacters(in: .whitespaces).lowercased()
            if t == "auto" || t.isEmpty { self = .auto; return }
            if t.hasSuffix("%"), let n = Double(t.dropLast()), n > 0, n <= 100 { self = .percent(CGFloat(n)); return }
            let digits = t.hasSuffix("px") ? String(t.dropLast(2)) : t
            if let n = Double(digits), n > 0, n.isFinite { self = .points(CGFloat(n)); return }
            return nil
        }

        public var text: String {
            switch self {
            case .auto: return "auto"
            case .points(let p): return Self.number(p)
            case .percent(let p): return Self.number(p) + "%"
            }
        }

        private static func number(_ value: CGFloat) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", Double(rounded))
        }
    }

    public var columnCount: Int { alignments.count }
    /// Header + body rows.
    public var rowCount: Int { rows.count + 1 }

    public init(header: [String], alignments: [Alignment], rows: [[String]], columnWidths: [ColumnWidth] = []) {
        let count = max(header.count, alignments.count, rows.map(\.count).max() ?? 0, 1)
        self.header = Self.pad(header, to: count, with: "")
        self.alignments = Self.pad(alignments, to: count, with: .none)
        self.rows = rows.map { Self.pad($0, to: count, with: "") }
        self.columnWidths = Self.pad(columnWidths, to: count, with: .auto)
        self.otherAttributes = []
    }

    /// The trailing `{…}` line, if `line` is one (any valid attribute block).
    static func attributeLine(_ line: String) -> MarkdownAttributes? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), t.hasSuffix("}") else { return nil }
        return MarkdownAttributes(source: t)
    }

    // MARK: - Parsing

    /// Parses a GFM table (header line, delimiter line, body lines).
    /// Returns nil if the delimiter row is missing or malformed.
    public init?(source: String) {
        var lines = source.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var attributes = MarkdownAttributes()
        if lines.count > 2, let last = lines.last, let parsed = Self.attributeLine(last) {
            attributes = parsed
            lines.removeLast()
        }
        guard lines.count >= 2 else { return nil }
        let header = Self.splitRow(lines[0])
        guard let alignments = Self.parseDelimiterRow(lines[1]), !header.isEmpty else { return nil }
        // GFM: the header and delimiter rows must agree on the column count;
        // body rows are padded / truncated to it.
        let count = alignments.count
        self.header = Self.pad(header, to: count, with: "")
        self.alignments = alignments
        self.rows = lines.dropFirst(2).map { Self.pad(Self.splitRow($0), to: count, with: "") }
        let widths = attributes.value(for: "cols").map { value in
            value.split(separator: ",", omittingEmptySubsequences: false).map { ColumnWidth(String($0)) ?? .auto }
        } ?? []
        self.columnWidths = Self.pad(widths, to: count, with: .auto)
        self.otherAttributes = attributes.items.filter { if case .pair("cols", _) = $0 { return false } else { return true } }
    }

    /// Splits one table line into unescaped, trimmed cells.
    static func splitRow(_ line: String) -> [String] {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|"), !s.hasSuffix("\\|") { s = s.dropLast() }

        var cells: [String] = []
        var current = ""
        var iterator = s.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\" {
                guard let next = iterator.next() else { current.append(ch); break }
                // `\|` is a literal pipe; any other escape is kept for the inline parser.
                if next == "|" { current.append("|") } else { current.append(ch); current.append(next) }
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func parseDelimiterRow(_ line: String) -> [Alignment]? {
        let cells = splitRow(line)
        var result: [Alignment] = []
        for cell in cells {
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":")
            let dashes = cell.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leading, trailing) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            case (false, false): result.append(.none)
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Serialization

    /// GFM source with every column padded to a common width. No trailing newline.
    public func markdown() -> String {
        let escapedHeader = header.map(Self.escape)
        let escapedRows = rows.map { $0.map(Self.escape) }
        var widths = escapedHeader.map { max(3, $0.count) }
        for row in escapedRows {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }

        func line(_ cells: [String]) -> String {
            let padded = cells.enumerated().map { i, cell in
                Self.align(cell, width: widths[i], alignment: alignments[i])
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        let delimiter = alignments.enumerated().map { i, alignment -> String in
            let w = widths[i]
            switch alignment {
            case .none: return String(repeating: "-", count: w)
            case .left: return ":" + String(repeating: "-", count: w - 1)
            case .right: return String(repeating: "-", count: w - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: w - 2) + ":"
            }
        }
        let delimiterLine = "| " + delimiter.joined(separator: " | ") + " |"
        var lines = [line(escapedHeader), delimiterLine] + escapedRows.map(line)
        if let attributes = attributesMarkdown() { lines.append(attributes) }
        return lines.joined(separator: "\n")
    }

    /// `{cols="30%,auto,120"}` plus any other kept entries; nil when there's nothing to write.
    func attributesMarkdown() -> String? {
        var parts: [String] = []
        if columnWidths.contains(where: { $0 != .auto }) {
            parts.append("cols=\"" + columnWidths.map(\.text).joined(separator: ",") + "\"")
        }
        let others = MarkdownAttributes(items: otherAttributes).markdown()
        if !others.isEmpty { parts.append(String(others.dropFirst().dropLast())) }
        return parts.isEmpty ? nil : "{" + parts.joined(separator: " ") + "}"
    }

    static func escape(_ cell: String) -> String {
        // Newlines can't live in a pipe-table cell; GFM convention is <br>.
        cell.replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func align(_ cell: String, width: Int, alignment: Alignment) -> String {
        let gap = max(0, width - cell.count)
        switch alignment {
        case .right: return String(repeating: " ", count: gap) + cell
        case .center:
            let left = gap / 2
            return String(repeating: " ", count: left) + cell + String(repeating: " ", count: gap - left)
        case .none, .left: return cell + String(repeating: " ", count: gap)
        }
    }

    // MARK: - Cell access (row 0 is the header)

    public subscript(row: Int, column: Int) -> String {
        get { row == 0 ? header[column] : rows[row - 1][column] }
        set {
            if row == 0 { header[column] = newValue } else { rows[row - 1][column] = newValue }
        }
    }

    // MARK: - Structural edits

    /// Inserts an empty body row so it ends up at `row` (1-based; 1 = first body row).
    public mutating func insertRow(at row: Int) {
        let index = min(max(row - 1, 0), rows.count)
        rows.insert(Array(repeating: "", count: columnCount), at: index)
    }

    /// Removes body row `row` (1-based). The header row can't be removed.
    public mutating func removeRow(_ row: Int) {
        guard row >= 1, row <= rows.count else { return }
        rows.remove(at: row - 1)
    }

    public mutating func moveRow(_ row: Int, to destination: Int) {
        guard row >= 1, row <= rows.count, destination >= 1, destination <= rows.count, row != destination else { return }
        rows.insert(rows.remove(at: row - 1), at: destination - 1)
    }

    public mutating func insertColumn(at column: Int, alignment: Alignment = .none) {
        let index = min(max(column, 0), columnCount)
        header.insert("", at: index)
        alignments.insert(alignment, at: index)
        columnWidths.insert(.auto, at: index)
        for i in rows.indices { rows[i].insert("", at: index) }
    }

    /// Removes `column`; a table always keeps at least one column.
    public mutating func removeColumn(_ column: Int) {
        guard columnCount > 1, column >= 0, column < columnCount else { return }
        header.remove(at: column)
        alignments.remove(at: column)
        columnWidths.remove(at: column)
        for i in rows.indices { rows[i].remove(at: column) }
    }

    public mutating func moveColumn(_ column: Int, to destination: Int) {
        guard column != destination,
              (0..<columnCount).contains(column), (0..<columnCount).contains(destination) else { return }
        header.insert(header.remove(at: column), at: destination)
        alignments.insert(alignments.remove(at: column), at: destination)
        columnWidths.insert(columnWidths.remove(at: column), at: destination)
        for i in rows.indices { rows[i].insert(rows[i].remove(at: column), at: destination) }
    }

    private static func pad<T>(_ array: [T], to count: Int, with fill: T) -> [T] {
        if array.count >= count { return Array(array.prefix(count)) }
        return array + Array(repeating: fill, count: count - array.count)
    }
}
