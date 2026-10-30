//
//  TableScopeSkipTests.swift
//  MarkdownEngineTests
//
//  Ported from swift-markdown-engine #96. styleTables used to parse, lay out
//  and render EVERY table per keystroke even though the apply loop clips its
//  output to the restyle scope. Now a table does that work only when it is in
//  scope; out-of-scope tables are hashed only when they share a length with a
//  rendering table, so duplicate tables keep stable sourceIDs.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Testing
@testable import MarkdownEngineCore

@MainActor
@Suite("styleTables scope skip")
struct TableScopeSkipTests {

    private func makeContext(text: String, scopeBounds: NSRange?) -> MarkdownStyler.StylingContext {
        #if os(macOS)
        _ = NSApplication.shared   // styleTables reads the app appearance
        #endif
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let font = PlatformFont.systemFont(ofSize: 15)
        var ctx = MarkdownStyler.StylingContext(
            nsText: text as NSString,
            tokens: tokens,
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .gray,
            latexMarkerFont: font,
            configuration: .default
        )
        ctx.scopeBounds = scopeBounds
        return ctx
    }

    private func tableRanges(in text: String) -> [NSRange] {
        MarkdownTokenizer.parseTokensViaAST(in: text).filter { $0.kind == .table }.map(\.range)
    }

    private func sourceIDs(_ attrs: [StyledRange], in range: NSRange) -> [Int] {
        attrs.filter { NSIntersectionRange($0.range, range).length > 0 }
            .compactMap { $0.attributes[.scrollableBlockSourceID] as? Int }
    }

    // Typing prose far from the tables renders none → every table skips.
    @Test func outOfScopeTablesEmitNothing() throws {
        let table = "| kappa | lambda |\n|---|---|\n| 5 | 6 |"
        let text = table + "\n\nmiddle\n\n" + table + "\n\ntrailing paragraph of prose"
        let ranges = tableRanges(in: text)
        #expect(ranges.count == 2)
        let last = try #require(ranges.last)
        let lo = NSMaxRange(last) + 2
        let ctx = makeContext(text: text, scopeBounds: NSRange(location: lo, length: (text as NSString).length - lo))

        let attrs = MarkdownStyler.styleTables(ctx)

        for range in ranges {
            #expect(attrs.filter { NSIntersectionRange($0.range, range).length > 0 }.isEmpty)
        }
    }

    // A table inside the restyle scope must still emit its attributes.
    @Test func inScopeTableStillEmitsItsAttributes() throws {
        let text = "| mu | nu |\n|---|---|\n| 7 | 8 |\n\nplain paragraph text here"
        let tableRange = try #require(tableRanges(in: text).first)
        let ctx = makeContext(text: text, scopeBounds: NSRange(location: 0, length: NSMaxRange(tableRange)))

        let attrs = MarkdownStyler.styleTables(ctx)

        let touching = attrs.filter { NSIntersectionRange($0.range, tableRange).length > 0 }
        #expect(!touching.isEmpty)
        #expect(touching.contains { $0.attributes[.spellingState] as? Int == 0 })
    }

    // Identical tables: a scoped restyle of the SECOND must tag it with the same
    // sourceID a full pass gives it, though the first is out of scope.
    @Test func duplicateTableKeepsItsSourceIDWhenScoped() throws {
        let table = "| omicron | pi |\n|---|---|\n| 1 | 2 |"
        let text = table + "\n\nbetween\n\n" + table + "\n"
        let ranges = tableRanges(in: text)
        #expect(ranges.count == 2)
        let second = try #require(ranges.last)

        let full = MarkdownStyler.styleTables(makeContext(text: text, scopeBounds: nil))
        let scoped = MarkdownStyler.styleTables(makeContext(text: text, scopeBounds: second))

        let expected = sourceIDs(full, in: second)
        #expect(!expected.isEmpty)
        #expect(sourceIDs(scoped, in: second) == expected)
        #expect(sourceIDs(full, in: ranges[0]) != expected)   // duplicates stay distinct
    }
}
