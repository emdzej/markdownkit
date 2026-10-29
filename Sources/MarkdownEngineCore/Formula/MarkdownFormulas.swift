//
//  MarkdownFormulas.swift
//  MarkdownEngine
//
//  Formulas in markdown tables, compatible with vitepress-plugin-markdownformula:
//  a cell link whose destination is `#` + an Excel-like formula,
//  `[?](#SUM(C1:C2))`, shows the computed value. Every `| … |` table of the
//  document is a sheet (columns A, B, …; the first body row is row 1); an
//  HTML comment `<!-- name -->` on the line directly above names it, else
//  it's `Sheet0`, `Sheet1`, … in document order. `name!C3` reads another
//  sheet. Tables are found the way the plugin finds them (consecutive
//  `|…|` lines, a delimiter second line, at least one body row) so sheet
//  numbering matches the published site.
//

import Foundation

public enum MarkdownFormulas {

    public struct Options: Equatable, Sendable {
        /// Significant digits kept after the leading one (HyperFormula's `precisionRounding`).
        public var precisionRounding: Int
        /// Count the header as row 1.
        public var includeHeaderInCellEnumeration: Bool

        public init(precisionRounding: Int = 4, includeHeaderInCellEnumeration: Bool = false) {
            self.precisionRounding = precisionRounding
            self.includeHeaderInCellEnumeration = includeHeaderInCellEnumeration
        }
    }

    /// One evaluated formula link.
    public struct FormulaResult: Equatable, Sendable {
        /// The `[label](#formula)` link in the document (UTF-16).
        public let range: NSRange
        /// The formula without its `#`, e.g. `SUM(C1:C2)`.
        public let formula: String
        /// The value as displayed: `11`, `5.5`, `TRUE`, text, or an error such as `#DIV/0!`.
        public let value: String
        public let isError: Bool
        /// The sheet (table) name and the cell's address in it, e.g. `table1`, `C3`.
        public let sheet: String
        public let cell: String
    }

    /// Every formula link in `document`'s tables with its value. Links whose
    /// formula doesn't parse (e.g. a heading anchor `[see](#intro)`) aren't included.
    public static func evaluate(document: String, options: Options = Options()) -> [FormulaResult] {
        Evaluation.make(document, options: options).results
    }

    /// The formula of a cell's text if it's a formula link, else nil.
    public static func formula(inCell text: String) -> String? {
        guard let match = linkMatch(in: text), FormulaParser.parse(match.formula) != nil else { return nil }
        return match.formula
    }

    /// What a typed cell value becomes: `=SUM(A1:A2)` → `[?](#SUM(A1:A2))` when
    /// it's a valid formula; anything else unchanged.
    public static func cellSource(fromTyped text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 1, trimmed.hasPrefix("="), !trimmed.hasPrefix("=="),
              FormulaParser.parse(String(trimmed.dropFirst())) != nil else { return text }
        return "[?](#\(trimmed.dropFirst()))"
    }

    /// Whether `formula` (without `#`) is a formula nmw can evaluate.
    public static func isFormula(_ formula: String) -> Bool {
        FormulaParser.parse(formula) != nil
    }

    // MARK: - Internals

    /// The plugin's `/\[.*?\]\(#(.*)\)/`: lazy label, greedy formula (so nested
    /// parentheses stay inside), first match in the cell.
    static func linkMatch(in text: String) -> (range: NSRange, formula: String)? {
        guard let match = linkPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (match.range, (text as NSString).substring(with: match.range(at: 1)))
    }

    nonisolated(unsafe) private static let linkPattern = try! NSRegularExpression(pattern: #"\[.*?\]\(#(.*)\)"#)

    /// The evaluated document: results, plus per-line cell values for the table grid.
    final class Evaluation: @unchecked Sendable {
        var results: [FormulaResult] = []
        /// Body / header line start (UTF-16) → column index → result.
        var cellsByLine: [Int: [Int: FormulaResult]] = [:]

        static func make(_ document: String, options: Options) -> Evaluation {
            let evaluation = Evaluation()
            guard document.contains("](#") else { return evaluation }
            let ns = document as NSString
            // Lines with their UTF-16 start, split like the plugin (`\r?\n`).
            var lines: [(text: String, start: Int)] = []
            var location = 0
            while location <= ns.length {
                var end = 0, contentsEnd = 0
                ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
                lines.append((ns.substring(with: NSRange(location: location, length: contentsEnd - location)), location))
                if end == location || end >= ns.length { break }
                location = end
            }

            // Consecutive `|…|` runs of at least two lines.
            let isRow = lines.map { line -> Bool in
                let t = line.text.trimmingCharacters(in: .whitespaces)
                return t.count >= 2 && t.hasPrefix("|") && t.hasSuffix("|")
            }
            var blocks: [[Int]] = []
            var run: [Int] = []
            for (i, row) in isRow.enumerated() {
                if row { run.append(i) } else { if run.count >= 2 { blocks.append(run) }; run = [] }
            }
            if run.count >= 2 { blocks.append(run) }

            struct Cell { let line: Int; let column: Int; let start: Int; let content: String }
            var sheets: [FormulaWorkbook.Sheet] = []
            var sheetCells: [[[Cell]]] = []
            for block in blocks {
                guard isDelimiter(lines[block[1]].text), block.count > 2 else { continue }
                var name = "Sheet\(sheets.count)"
                if block[0] > 0, let comment = commentName(lines[block[0] - 1].text) { name = comment }
                let rowLines = (options.includeHeaderInCellEnumeration ? [block[0]] : []) + block.dropFirst(2)
                var rows: [[Cell]] = []
                for l in rowLines {
                    rows.append(splitCells(lines[l].text).map { Cell(line: l, column: $0.column, start: lines[l].start + $0.offset, content: $0.text) })
                }
                sheets.append(FormulaWorkbook.Sheet(name: name, cells: rows.map { row in
                    row.map { cell -> FormulaWorkbook.Content in
                        if let match = MarkdownFormulas.linkMatch(in: cell.content) {
                            return .formula(FormulaParser.parse(match.formula))
                        }
                        let text = cell.content.trimmingCharacters(in: .whitespaces)
                        if text.hasPrefix("="), text.count > 1 { return .formula(FormulaParser.parse(String(text.dropFirst()))) }
                        return .literal(FormulaValue(literal: text))
                    }
                }))
                sheetCells.append(rows)
            }

            let evaluator = FormulaEvaluator(workbook: FormulaWorkbook(sheets: sheets), precisionRounding: options.precisionRounding)
            for (s, rows) in sheetCells.enumerated() {
                for (r, row) in rows.enumerated() {
                    for (c, cell) in row.enumerated() {
                        guard let match = MarkdownFormulas.linkMatch(in: cell.content),
                              FormulaParser.parse(match.formula) != nil else { continue }
                        let value = evaluator.displayValue(sheet: s, row: r, column: c)
                        var isError = false
                        if case .error = value { isError = true }
                        let rowNumber = r + 1
                        let result = FormulaResult(
                            range: NSRange(location: cell.start + match.range.location, length: match.range.length),
                            formula: match.formula,
                            value: FormulaEvaluator.text(value),
                            isError: isError,
                            sheet: sheets[s].name,
                            cell: columnName(c) + String(rowNumber)
                        )
                        evaluation.results.append(result)
                        evaluation.cellsByLine[lines[cell.line].start, default: [:]][cell.column] = result
                    }
                }
            }
            return evaluation
        }

        /// The plugin's delimiter test, `/(?:\|.+?[-]+.+?)+\|/`.
        private static func isDelimiter(_ line: String) -> Bool {
            line.range(of: #"(?:\|.+?[-]+.+?)+\|"#, options: .regularExpression) != nil
        }

        private static func commentName(_ line: String) -> String? {
            guard let open = line.range(of: "<!--"), let close = line.range(of: "-->", range: open.upperBound..<line.endIndex) else { return nil }
            let name = line[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }

        /// The cells between the outer pipes, with their UTF-16 offset in the line.
        /// Unlike the plugin, an escaped `\|` stays inside its cell (as the grid shows it).
        private static func splitCells(_ line: String) -> [(column: Int, offset: Int, text: String)] {
            let units = Array(line.utf16)
            var pieces: [(offset: Int, text: String)] = []
            var start = 0
            var i = 0
            while i < units.count {
                if units[i] == 0x5C, i + 1 < units.count { i += 2; continue }   // backslash escape
                if units[i] == 0x7C {
                    pieces.append((start, String(decoding: units[start..<i], as: UTF16.self)))
                    start = i + 1
                }
                i += 1
            }
            pieces.append((start, String(decoding: units[start..<units.count], as: UTF16.self)))
            // Drop what's before the first pipe and after the last.
            guard pieces.count >= 3 else { return [] }
            return pieces.dropFirst().dropLast().enumerated().map { ($0.offset, $0.element.offset, $0.element.text) }
        }
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    // MARK: Cache for styling

    nonisolated(unsafe) private static var cachedText: String?
    nonisolated(unsafe) private static var cachedEvaluation: Evaluation?
    private static let cacheLock = NSLock()

    /// The evaluation of `document`, reusing the last one while the text is unchanged.
    static func cachedEvaluation(for document: String) -> Evaluation {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedEvaluation, cachedText == document { return cachedEvaluation }
        let evaluation = Evaluation.make(document, options: Options())
        cachedText = document
        cachedEvaluation = evaluation
        return evaluation
    }

    /// Paragraph ranges of tables with formula links, other than the one at `edited`:
    /// their values may depend on the edited table.
    static func dependentTableParagraphs(in document: String, excluding edited: NSRange) -> [NSRange] {
        let ns = document as NSString
        var ranges: [NSRange] = []
        for result in cachedEvaluation(for: document).results where NSIntersectionRange(result.range, edited).length == 0 && !NSLocationInRange(result.range.location, edited) {
            let paragraph = ns.paragraphRange(for: result.range)
            if ranges.last.map({ NSIntersectionRange($0, paragraph).length > 0 || NSMaxRange($0) == paragraph.location }) == true {
                ranges[ranges.count - 1] = NSUnionRange(ranges[ranges.count - 1], paragraph)
            } else {
                ranges.append(paragraph)
            }
        }
        return ranges
    }
}
