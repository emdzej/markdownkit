//
//  MarkdownAST.swift
//  MarkdownEngine
//
//  Phase 2.5 foundation: the semantic document AST. Combines the block-structure
//  pass (BlockParser) with the inline pass (InlineParser) into one tree of
//  `BlockNode`s, each inline-bearing block carrying its parsed inline children
//  in absolute document coordinates. The AST-native styler (next increments)
//  walks this tree instead of consuming flat tokens.
//

import Foundation

/// One list-item line: marker run, optional GFM checkbox, and indent column count.
struct ListItem: Equatable {
    let range: NSRange          // the item's full line (incl. trailing newline)
    let marker: NSRange
    let ordered: Bool
    let number: Int?            // ordered start value, e.g. `5.` → 5
    let checkbox: NSRange?
    let checked: Bool
    let indent: Int
    let contentRange: NSRange   // text after the marker (and checkbox)
    let inlines: [InlineNode]
}

/// A top-level block in the document AST.
indirect enum BlockNode: Equatable {
    case paragraph(range: NSRange, inlines: [InlineNode])
    case heading(level: Int, range: NSRange, markers: [NSRange], inlines: [InlineNode])
    case blockquote(range: NSRange, inlines: [InlineNode])
    case list(range: NSRange, items: [ListItem])
    case codeBlock(range: NSRange)
    case blockLatex(range: NSRange)
    case table(range: NSRange)
    case thematicBreak(range: NSRange)
    case blank(range: NSRange)
    case frontmatter(range: NSRange)

    var range: NSRange {
        switch self {
        case .paragraph(let r, _), .heading(_, let r, _, _), .blockquote(let r, _),
             .list(let r, _), .codeBlock(let r), .blockLatex(let r), .table(let r),
             .thematicBreak(let r), .blank(let r), .frontmatter(let r):
            return r
        }
    }
}

enum DocumentAST {

    private static let hash: unichar = 0x23
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    /// Build the document AST; `scopedRanges` parses inlines only for intersecting blocks.
    static func parse(_ text: String, scopedRanges: [NSRange]? = nil) -> [BlockNode] {
        let ns = text as NSString
        let blocks = BlockParser.parse(text)
        guard let scopedRanges else {
            return blocks.map { node(for: $0, ns: ns, scopedRanges: nil) }
        }
        // Scoped mode: skip building BlockNodes for blocks outside the edit, and
        // hand each block only the scopes that reach it (a list then builds only
        // the items those scopes touch). Blocks tile the document in order, so
        // one sweep over the normalized (sorted, merged) scopes replaces testing
        // every scope against every block. (Ported from swift-markdown-engine #149.)
        let scopes = normalizeScopes(scopedRanges, documentLength: ns.length)
        var out: [BlockNode] = []
        var ci = 0
        for block in blocks {
            while ci < scopes.count, NSMaxRange(scopes[ci]) <= block.range.location { ci += 1 }
            guard ci < scopes.count else { break }
            var intersections: [NSRange] = []
            var si = ci
            while si < scopes.count, scopes[si].location < NSMaxRange(block.range) {
                intersections.append(scopes[si])
                si += 1
            }
            if !intersections.isEmpty {
                out.append(node(for: block, ns: ns, scopedRanges: intersections))
            }
        }
        return out
    }

    /// Clamp scopes to the document, drop empty/invalid ones, then sort and
    /// merge them once so every scoped consumer sees one monotonic view of the
    /// edit region.
    private static func normalizeScopes(_ ranges: [NSRange], documentLength: Int) -> [NSRange] {
        let sorted = ranges.compactMap { range -> NSRange? in
            guard range.location != NSNotFound else { return nil }
            let (rawEnd, overflowed) = range.location.addingReportingOverflow(range.length)
            let start = max(0, range.location)
            let end = min(documentLength, overflowed ? Int.max : rawEnd)
            return end > start ? NSRange(location: start, length: end - start) : nil
        }
        .sorted { $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location }

        var result: [NSRange] = []
        result.reserveCapacity(sorted.count)
        for range in sorted {
            if let previous = result.last, range.location <= NSMaxRange(previous) {
                let end = max(NSMaxRange(previous), NSMaxRange(range))
                result[result.count - 1].length = end - previous.location
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func inScope(_ range: NSRange, _ scopedRanges: [NSRange]?) -> Bool {
        guard let scopedRanges else { return true }
        return scopedRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    private static func node(for block: Block, ns: NSString, scopedRanges: [NSRange]?) -> BlockNode {
        let scoped = inScope(block.range, scopedRanges)
        switch block.kind {
        case .paragraph:
            return .paragraph(range: block.range, inlines: scoped ? InlineParser.parse(ns, range: block.range) : [])
        case .heading:
            return heading(block.range, ns, scoped: scoped)
        case .blockquote:
            return .blockquote(range: block.range, inlines: scoped ? InlineParser.parse(ns, range: block.range) : [])
        case .list:
            return list(block.range, ns, scopedRanges: scopedRanges)
        case .fencedCode:
            return .codeBlock(range: block.range)
        case .blockLatex:
            return .blockLatex(range: block.range)
        case .table:
            return .table(range: block.range)
        case .thematicBreak:
            return .thematicBreak(range: block.range)
        case .blank:
            return .blank(range: block.range)
        case .frontmatter:
            return .frontmatter(range: block.range)
        }
    }

    /// ATX heading: optional indent, `#`×level, space(s), then inline content.
    private static func heading(_ range: NSRange, _ ns: NSString, scoped: Bool = true) -> BlockNode {
        let end = NSMaxRange(range)
        var i = range.location
        while i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
        let hashStart = i
        var level = 0
        while i < end, ns.character(at: i) == hash { level += 1; i += 1 }

        var contentStart = i
        while contentStart < end, ns.character(at: contentStart) == space { contentStart += 1 }
        // Markers span `#`(s) plus trailing space(s) so the whole syntax collapses on shrink.
        let markers = [NSRange(location: hashStart, length: contentStart - hashStart)]
        var contentEnd = end
        while contentEnd > contentStart, isLineBreak(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let contentRange = NSRange(location: contentStart, length: contentEnd - contentStart)

        return .heading(level: level, range: range, markers: markers,
                        inlines: scoped ? InlineParser.parse(ns, range: contentRange) : [])
    }

    /// Split a list block into one `ListItem` per physical line. A scoped pass
    /// builds only the lines its scopes touch, so a keystroke in a long list
    /// no longer re-parses every item's inlines. The styler and the restyle's
    /// apply loop are clipped to the same scopes, so the skipped items are never
    /// painted anyway. (Ported from swift-markdown-engine #149.)
    private static func list(_ range: NSRange, _ ns: NSString, scopedRanges: [NSRange]? = nil) -> BlockNode {
        var lineRanges: [NSRange] = []
        if let scopedRanges {
            for scope in scopedRanges {
                let intersection = NSIntersectionRange(scope, range)
                guard intersection.length > 0 else { continue }
                let expanded = NSIntersectionRange(ns.lineRange(for: intersection), range)
                var cursor = expanded.location
                let end = NSMaxRange(expanded)
                while cursor < end {
                    let line = NSIntersectionRange(ns.lineRange(for: NSRange(location: cursor, length: 0)), range)
                    if line.length > 0, lineRanges.last != line { lineRanges.append(line) }
                    let next = NSMaxRange(line)
                    guard next > cursor else { break }
                    cursor = next
                }
            }
        } else {
            var cursor = range.location
            let end = NSMaxRange(range)
            while cursor < end {
                let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
                lineRanges.append(line)
                cursor = NSMaxRange(line)
            }
        }
        return .list(range: range, items: lineRanges.map { listItem($0, ns) })
    }

    /// Parse one list-item line: indent, marker, optional task checkbox, inline content.
    private static func listItem(_ lineRange: NSRange, _ ns: NSString, scoped: Bool = true) -> ListItem {
        let end = NSMaxRange(lineRange)
        var i = lineRange.location
        var indent = 0
        while i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1; indent += 1 }
        let markerStart = i
        var ordered = false
        var number: Int?
        let c = i < end ? ns.character(at: i) : 0
        if c == 0x2D || c == 0x2A || c == 0x2B {        // - * +
            i += 1
        } else {                                        // N. / N)
            var value = 0
            var digits = 0
            while i < end, ns.character(at: i) >= 0x30, ns.character(at: i) <= 0x39, digits < 9 {
                value = value * 10 + Int(ns.character(at: i) - 0x30); i += 1; digits += 1
            }
            ordered = true
            number = value
            if i < end { i += 1 }                       // the `.` or `)`
        }
        let marker = NSRange(location: markerStart, length: i - markerStart)
        if i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
        var checkbox: NSRange?
        var checked = false
        if i + 2 < end, ns.character(at: i) == 0x5B, ns.character(at: i + 2) == 0x5D {   // [ x ]
            let mid = ns.character(at: i + 1)
            if mid == space || mid == 0x78 || mid == 0x58 {     // space / x / X
                checkbox = NSRange(location: i, length: 3)
                checked = (mid == 0x78 || mid == 0x58)
                i += 3
                if i < end, ns.character(at: i) == space || ns.character(at: i) == tab { i += 1 }
            }
        }
        var contentEnd = end
        while contentEnd > i, isLineBreak(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let content = NSRange(location: i, length: max(0, contentEnd - i))
        return ListItem(range: lineRange, marker: marker, ordered: ordered, number: number,
                        checkbox: checkbox, checked: checked, indent: indent,
                        contentRange: content, inlines: scoped ? InlineParser.parse(ns, range: content) : [])
    }

    private static func isLineBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
}
