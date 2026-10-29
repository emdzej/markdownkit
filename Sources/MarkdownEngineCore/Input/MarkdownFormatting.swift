//
//  MarkdownFormatting.swift
//  MarkdownEngine
//
//  Formatting commands (bold, headings, lists, tables…) as pure edits of
//  the markdown source: given the text and the selection, each returns the
//  range to replace, the replacement, and the selection afterwards. Shared
//  by both platforms and by `MarkdownEditorController`, so toolbars and
//  menus behave the same everywhere.
//

import Foundation

/// One edit to the source: replace `range` with `replacement`, then select `selection`.
public struct MarkdownFormattingEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange
}

public enum MarkdownFormatting {

    /// Inline styles that wrap text in a marker.
    public enum InlineStyle: String, CaseIterable, Sendable {
        case bold, italic, strikethrough, code

        public var marker: String {
            switch self {
            case .bold: "**"
            case .italic: "*"
            case .strikethrough: "~~"
            case .code: "`"
            }
        }
    }

    /// What a line is: plain text, a heading, a list item or a quote.
    public enum BlockStyle: String, CaseIterable, Sendable {
        case body, title, heading, subheading, bullet, numbered, task, quote

        /// The prefix this style gives a line (numbered lists get their number elsewhere).
        var prefix: String {
            switch self {
            case .body: ""
            case .title: "# "
            case .heading: "## "
            case .subheading: "### "
            case .bullet: "- "
            case .numbered: "1. "
            case .task: "- [ ] "
            case .quote: "> "
            }
        }
    }

    // MARK: Inline

    /// Wraps the selection in the style's marker, or unwraps it when it's
    /// already wrapped (markers inside or right outside the selection). With
    /// no selection, a word under the caret is wrapped; elsewhere an empty
    /// pair is inserted with the caret between.
    public static func toggle(_ style: InlineStyle, in text: String, selection: NSRange) -> MarkdownFormattingEdit {
        let ns = text as NSString
        let marker = style.marker
        let m = (marker as NSString).length
        var range = selection

        if range.length == 0, let word = wordRange(at: range.location, in: ns) {
            range = word
        }

        // Markers just outside the selection: **|text|**
        if range.location >= m, NSMaxRange(range) + m <= ns.length,
           ns.substring(with: NSRange(location: range.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(range), length: m)) == marker,
           !isPartOfLongerMarker(style, ns: ns, before: range.location - m, after: NSMaxRange(range) + m) {
            let outer = NSRange(location: range.location - m, length: range.length + 2 * m)
            let inner = ns.substring(with: range)
            return MarkdownFormattingEdit(range: outer, replacement: inner,
                                          selection: shifted(selection, by: -m, within: range))
        }
        // Markers inside the selection: |**text**|
        let selected = ns.substring(with: range)
        if range.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker),
           !(style == .italic && selected.hasPrefix("**") && !selected.hasPrefix("***")) {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            return MarkdownFormattingEdit(range: range, replacement: inner,
                                          selection: NSRange(location: range.location, length: (inner as NSString).length))
        }
        // Wrap.
        let replacement = marker + selected + marker
        let newSelection = range.length == 0
            ? NSRange(location: range.location + m, length: 0)
            : (selection.length == 0
                ? NSRange(location: selection.location + m, length: 0)
                : NSRange(location: range.location + m, length: range.length))
        return MarkdownFormattingEdit(range: range, replacement: replacement, selection: newSelection)
    }

    /// `*` next to another `*` is bold, not italic.
    private static func isPartOfLongerMarker(_ style: InlineStyle, ns: NSString, before: Int, after: Int) -> Bool {
        guard style == .italic else { return false }
        let charBefore = before > 0 ? ns.substring(with: NSRange(location: before - 1, length: 1)) : ""
        let charAfter = after < ns.length ? ns.substring(with: NSRange(location: after, length: 1)) : ""
        return charBefore == "*" || charAfter == "*"
    }

    private static func shifted(_ selection: NSRange, by delta: Int, within range: NSRange) -> NSRange {
        NSRange(location: max(range.location + delta, selection.location + delta), length: selection.length)
    }

    /// The word (letters, digits, `_`) containing or touching `location`.
    static func wordRange(at location: Int, in ns: NSString) -> NSRange? {
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let scalar = UnicodeScalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        guard isWord(location) || isWord(location - 1) else { return nil }
        var start = location, end = location
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: Blocks

    private static let blockPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d{1,9}[.)][ \t]+)?"#)

    /// The style of the line containing `location`.
    public static func blockStyle(at location: Int, in text: String) -> BlockStyle {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        return parseLine(ns.substring(with: line)).style
    }

    private static func parseLine(_ line: String) -> (indent: String, prefixLength: Int, style: BlockStyle) {
        let ns = line as NSString
        guard let match = blockPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return ("", 0, .body)
        }
        let indent = ns.substring(with: match.range(at: 1))
        let prefixRange = match.range(at: 2)
        guard prefixRange.location != NSNotFound else { return (indent, 0, .body) }
        let prefix = ns.substring(with: prefixRange).trimmingCharacters(in: .whitespaces)
        let style: BlockStyle
        if prefix.hasPrefix("#") {
            switch prefix.count {
            case 1: style = .title
            case 2: style = .heading
            default: style = .subheading
            }
        } else if prefix.hasPrefix(">") {
            style = .quote
        } else if prefix.contains("[") {
            style = .task
        } else if prefix.first?.isNumber == true {
            style = .numbered
        } else {
            style = .bullet
        }
        return (indent, prefixRange.length, style)
    }

    /// Gives every line of the selection `style`, replacing heading, list
    /// and quote prefixes. If they all have it already, they become body
    /// text. Numbered lines are numbered from 1.
    public static func setBlock(_ style: BlockStyle, in text: String, selection: NSRange) -> MarkdownFormattingEdit {
        let ns = text as NSString
        let linesRange = ns.lineRange(for: selection)
        let block = ns.substring(with: linesRange)
        var lines = block.components(separatedBy: "\n")
        let trailingNewline = block.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        if lines.isEmpty { lines = [""] }

        let parsed = lines.map(parseLine)
        let target: BlockStyle = parsed.allSatisfy({ $0.style == style }) && style != .body ? .body : style

        var newLines: [String] = []
        var caretShift = 0
        for (i, (line, info)) in zip(lines, parsed).enumerated() {
            let ns = line as NSString
            let content = ns.substring(from: (info.indent as NSString).length + info.prefixLength)
            // Headings don't keep list indentation.
            let indent = [.title, .heading, .subheading].contains(target) ? "" : info.indent
            let prefix = target == .numbered ? "\(i + 1). " : target.prefix
            let newLine = indent + prefix + content
            if i == 0 { caretShift = (newLine as NSString).length - ns.length }
            newLines.append(newLine)
        }
        let replacement = newLines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let newSelection: NSRange
        if selection.length == 0 {
            newSelection = NSRange(location: max(linesRange.location, selection.location + caretShift), length: 0)
        } else {
            newSelection = NSRange(location: linesRange.location,
                                   length: (replacement as NSString).length - (trailingNewline ? 1 : 0))
        }
        return MarkdownFormattingEdit(range: linesRange, replacement: replacement, selection: newSelection)
    }

    /// Indents (one tab) or outdents the selected lines.
    public static func indent(_ deeper: Bool, in text: String, selection: NSRange) -> MarkdownFormattingEdit {
        let ns = text as NSString
        let linesRange = ns.lineRange(for: selection)
        let block = ns.substring(with: linesRange)
        var lines = block.components(separatedBy: "\n")
        let trailingNewline = block.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        var firstShift = 0
        let newLines = lines.enumerated().map { i, line -> String in
            let result: String
            if deeper {
                result = "\t" + line
            } else if line.hasPrefix("\t") {
                result = String(line.dropFirst())
            } else {
                let spaces = line.prefix(4).prefix { $0 == " " }.count
                result = String(line.dropFirst(spaces))
            }
            if i == 0 { firstShift = (result as NSString).length - (line as NSString).length }
            return result
        }
        let replacement = newLines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let newSelection = selection.length == 0
            ? NSRange(location: max(linesRange.location, selection.location + firstShift), length: 0)
            : NSRange(location: linesRange.location, length: (replacement as NSString).length - (trailingNewline ? 1 : 0))
        return MarkdownFormattingEdit(range: linesRange, replacement: replacement, selection: newSelection)
    }

    /// An empty table with a header row, on lines of its own, with the caret in the first header cell.
    public static func insertTable(columns: Int = 2, rows: Int = 2, in text: String, selection: NSRange) -> MarkdownFormattingEdit {
        let ns = text as NSString
        let columns = max(1, columns), rows = max(1, rows)
        func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        let header = row((1...columns).map { _ in "   " })
        let delimiter = "|" + Array(repeating: "-----", count: columns).joined(separator: "|") + "|"
        let body = (0..<rows).map { _ in row((1...columns).map { _ in "   " }) }
        var table = ([header, delimiter] + body).joined(separator: "\n")

        // Blank line before and after unless already at a block boundary.
        let start = selection.location
        let end = NSMaxRange(selection)
        let before = start > 0 ? ns.substring(with: NSRange(location: 0, length: start)) : ""
        let after = end < ns.length ? ns.substring(from: end) : ""
        var lead = ""
        if !before.isEmpty {
            if !before.hasSuffix("\n") { lead = "\n\n" } else if !before.hasSuffix("\n\n") { lead = "\n" }
        }
        let trail = after.hasPrefix("\n\n") ? "" : (after.hasPrefix("\n") ? "\n" : "\n\n")
        table = lead + table + trail
        let caret = selection.location + (lead as NSString).length + 2
        return MarkdownFormattingEdit(range: selection, replacement: table, selection: NSRange(location: caret, length: 0))
    }
}

// MARK: - Checklists

extension MarkdownFormatting {

    /// What to do with a checklist.
    public enum ChecklistAction: Sendable {
        /// Checks the selected items (unchecks them when they're all checked);
        /// lines that aren't items yet become unchecked items.
        case toggleChecked
        case checkAll, uncheckAll
        case moveCheckedToBottom
        case deleteChecked
    }

    private static let taskLine = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)\[([ xX])\]"#)

    /// `(indent width, checked)` when `line` is a task item.
    static func taskInfo(_ line: String) -> (indent: Int, checked: Bool, box: NSRange)? {
        let ns = line as NSString
        guard let m = taskLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: m.range(at: 1)).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let mark = ns.substring(with: m.range(at: 4))
        let box = NSRange(location: m.range(at: 4).location - 1, length: 3)
        return (indent, mark != " ", box)
    }

    /// Applies `action` to the checklist at the selection (the consecutive
    /// task lines around it, nested items included).
    public static func checklist(_ action: ChecklistAction, in text: String, selection: NSRange) -> MarkdownFormattingEdit? {
        let ns = text as NSString
        if case .toggleChecked = action {
            return toggleChecked(in: text, selection: selection)
        }
        guard let block = checklistBlock(in: ns, at: selection.location) else { return nil }
        var lines = ns.substring(with: block).components(separatedBy: "\n")
        let trailingNewline = lines.last == ""
        if trailingNewline { lines.removeLast() }

        switch action {
        case .checkAll, .uncheckAll:
            lines = lines.map { setChecked(action == .checkAll, line: $0) }
        case .moveCheckedToBottom:
            lines = sortedCheckedLast(lines)
        case .deleteChecked:
            lines = groups(lines).filter { !($0.checked) }.flatMap(\.lines)
        case .toggleChecked:
            break
        }
        let replacement = lines.joined(separator: "\n") + (trailingNewline && !lines.isEmpty ? "\n" : "")
        let caret = min(selection.location, block.location + (replacement as NSString).length)
        return MarkdownFormattingEdit(range: block, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// The checkbox at `boxLocation` toggled; with `moveCheckedToBottom`, a
    /// newly checked item also moves below its unchecked siblings. One edit.
    public static func toggleCheckbox(at boxLocation: Int, in text: String, moveCheckedToBottom: Bool) -> MarkdownFormattingEdit? {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: boxLocation, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard let info = taskInfo(line) else { return nil }
        let toggled = setChecked(!info.checked, line: line)
        guard moveCheckedToBottom, !info.checked, let block = checklistBlock(in: ns, at: boxLocation) else {
            let range = NSRange(location: lineRange.location, length: (line as NSString).length)
            return MarkdownFormattingEdit(range: range, replacement: toggled, selection: NSRange(location: lineRange.location, length: 0))
        }
        var lines = ns.substring(with: block).components(separatedBy: "\n")
        let trailingNewline = lines.last == ""
        if trailingNewline { lines.removeLast() }
        let index = ns.substring(with: NSRange(location: block.location, length: lineRange.location - block.location))
            .components(separatedBy: "\n").count - 1
        guard lines.indices.contains(index) else { return nil }
        lines[index] = toggled
        let sorted = sortedCheckedLast(lines)
        let replacement = sorted.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        return MarkdownFormattingEdit(range: block, replacement: replacement, selection: NSRange(location: block.location, length: 0))
    }

    private static func toggleChecked(in text: String, selection: NSRange) -> MarkdownFormattingEdit {
        let ns = text as NSString
        let linesRange = ns.lineRange(for: selection)
        let block = ns.substring(with: linesRange)
        var lines = block.components(separatedBy: "\n")
        let trailingNewline = block.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        let infos = lines.map(taskInfo)
        if infos.allSatisfy({ $0 == nil }) {
            return setBlock(.task, in: text, selection: selection)
        }
        let check = infos.contains { $0 != nil && $0!.checked == false }
        let newLines = lines.map { taskInfo($0) == nil ? $0 : setChecked(check, line: $0) }
        let replacement = newLines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        return MarkdownFormattingEdit(range: linesRange, replacement: replacement, selection: selection)
    }

    private static func setChecked(_ checked: Bool, line: String) -> String {
        guard let info = taskInfo(line) else { return line }
        return (line as NSString).replacingCharacters(in: info.box, with: checked ? "[x]" : "[ ]")
    }

    /// Consecutive lines that are task items or nested under one.
    static func checklistBlock(in ns: NSString, at location: Int) -> NSRange? {
        let here = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        func isPart(_ range: NSRange) -> Bool {
            let line = ns.substring(with: range).trimmingCharacters(in: .newlines)
            if taskInfo(line) != nil { return true }
            // A continuation nested under an item (indented, not blank).
            return !line.trimmingCharacters(in: .whitespaces).isEmpty && (line.hasPrefix("  ") || line.hasPrefix("\t"))
        }
        guard taskInfo(ns.substring(with: here).trimmingCharacters(in: .newlines)) != nil || isPart(here) else { return nil }
        var start = here.location
        while start > 0 {
            let prev = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            guard isPart(prev) else { break }
            start = prev.location
        }
        var end = NSMaxRange(here)
        while end < ns.length {
            let next = ns.lineRange(for: NSRange(location: end, length: 0))
            guard isPart(next) else { break }
            end = NSMaxRange(next)
        }
        // Don't take a trailing blank line.
        return NSRange(location: start, length: end - start)
    }

    /// Items with the lines nested under them; lines before the first item stay first.
    private static func groups(_ lines: [String]) -> [(lines: [String], checked: Bool)] {
        var result: [(lines: [String], checked: Bool)] = []
        var baseIndent: Int?
        for line in lines {
            if let info = taskInfo(line), info.indent <= (baseIndent ?? info.indent) {
                baseIndent = baseIndent ?? info.indent
                result.append(([line], info.checked))
            } else if result.isEmpty {
                result.append(([line], false))
            } else {
                result[result.count - 1].lines.append(line)
            }
        }
        return result
    }

    private static func sortedCheckedLast(_ lines: [String]) -> [String] {
        let all = groups(lines)
        return (all.filter { !$0.checked } + all.filter(\.checked)).flatMap(\.lines)
    }

    /// `(done, total)` task items in `text`, for progress in note lists.
    public static func checklistProgress(in text: String) -> (done: Int, total: Int) {
        var done = 0, total = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let info = taskInfo(String(line)) { total += 1; if info.checked { done += 1 } }
        }
        return (done, total)
    }
}
