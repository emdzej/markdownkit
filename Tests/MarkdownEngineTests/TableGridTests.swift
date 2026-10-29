//
//  TableGridTests.swift
//  MarkdownEngineTests
//
//  Table grid plumbing: layout hit-testing, which tables reveal their raw
//  source, and the render info the styler hands to the grid overlay.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Testing
@testable import MarkdownEngineCore

@MainActor
@Suite("Table grid")
struct TableGridTests {

    private let doc = "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nOutro"
    private var tableStart: Int { (doc as NSString).range(of: "| a").location }

    private func layout(_ rows: [[String]]) -> TableGridLayout {
        let font = PlatformFont.systemFont(ofSize: 14)
        let cells = rows.map { $0.map { NSAttributedString(string: $0, attributes: [.font: font]) } }
        return TableGridLayout(cells: cells, columnCount: rows[0].count, baseFont: font)
    }

    @Test func layoutHitTestsEveryCellCenter() {
        let l = layout([["Name", "Kind"], ["Parser", "core"], ["UI", "new"]])
        #expect(l.rowCount == 3 && l.columnCount == 2)
        for row in 0..<3 {
            for column in 0..<2 {
                let rect = l.cellRect(row: row, column: column)
                let hit = l.cell(at: CGPoint(x: rect.midX, y: rect.midY))
                #expect(hit?.row == row && hit?.column == column)
            }
        }
        #expect(l.cell(at: CGPoint(x: -1, y: 1)) == nil)
        #expect(l.cell(at: CGPoint(x: 1, y: l.size.height + 1)) == nil)
    }

    @Test func layoutColumnsFitWidestCell() {
        let l = layout([["a", "b"], ["a much longer cell", "b"]])
        let first = l.contentRect(row: 0, column: 0).width
        let second = l.contentRect(row: 0, column: 1).width
        #expect(first > second)
    }

    @Test func caretPolicyRevealsTableUnderCaret() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: doc)
        let tableIndex = tokens.firstIndex { $0.kind == .table }!
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: tableStart + 2, length: 0), tokens: tokens, in: doc as NSString
        )
        #expect(active.contains(tableIndex))
    }

    @Test func gridPolicyRevealsOnlyTheChosenTable() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: doc)
        let tableIndex = tokens.firstIndex { $0.kind == .table }!
        let caretInTable = NSRange(location: tableStart + 2, length: 0)
        let hidden = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: caretInTable, tokens: tokens, in: doc as NSString, tableReveal: .only(nil)
        )
        #expect(!hidden.contains(tableIndex))
        let revealed = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: 0, length: 0), tokens: tokens, in: doc as NSString,
            tableReveal: .only(tableStart)
        )
        #expect(revealed.contains(tableIndex))
    }

    @Test func stylerAttachesRenderInfoForInactiveTables() throws {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let ranges = MarkdownStyler.styleAttributes(
            text: doc, fontName: "Helvetica", fontSize: 14,
            caretLocation: 0, activeTokenIndices: []
        )
        let info = try #require(ranges.lazy.compactMap { $0.1[.tableRenderInfo] as? TableRenderInfo }.first)
        #expect(info.table.header == ["a", "b"])
        #expect(info.sourceRange.location == tableStart)
        #expect((doc as NSString).substring(with: info.sourceRange).hasSuffix("| 1 | 2 |"))
        #expect(info.image.size == info.layout.size)
        // The grid overlay finds tables by their source ID on the anchor.
        #expect(ranges.contains { $0.1[.scrollableBlockSourceID] != nil })
    }

    @Test func editorGrowsAwayFromTheAlignmentEdgeWithinTheTable() {
        let l = layout([["a", "b", "c"], ["1", "2", "3"]])
        let cell = l.contentRect(row: 1, column: 1)
        #expect(l.editorFrame(row: 1, column: 1, textWidth: 1, alignment: .left) == cell)
        let left = l.editorFrame(row: 1, column: 1, textWidth: cell.width + 20, alignment: .left)
        #expect(left.minX == cell.minX && left.width == cell.width + 20)
        let right = l.editorFrame(row: 1, column: 1, textWidth: cell.width + 20, alignment: .right)
        #expect(right.maxX == cell.maxX && right.width == cell.width + 20)
        let huge = l.editorFrame(row: 1, column: 1, textWidth: 10_000, alignment: .center)
        #expect(huge.minX >= 0 && huge.maxX <= l.size.width)
    }
}
