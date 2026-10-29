//
//  TableWidthsTests.swift
//  MarkdownEngineTests
//
//  Column widths (`{cols="…"}` after a table), the layout honoring them,
//  the editing markers, and the row / column handle commands.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Testing
@testable import MarkdownEngineCore

@MainActor
@Suite("Table widths and markers")
struct TableWidthsTests {

    private let source = "| a | b | c |\n|---|:-:|---|\n| 1 | 2 | 3 |\n{cols=\"30%,auto,120\" .wide}"

    // MARK: Attribute line

    @Test func parsesWidthsAndKeepsOtherEntries() throws {
        let table = try #require(MarkdownTable(source: source))
        #expect(table.columnWidths == [.percent(30), .auto, .points(120)])
        #expect(table.otherAttributes == [.class("wide")])
        #expect(table.rows == [["1", "2", "3"]])
    }

    @Test func serializesTheAttributeLineAndDropsItWhenAllAuto() throws {
        var table = try #require(MarkdownTable(source: source))
        #expect(table.markdown().hasSuffix("\n{cols=\"30%,auto,120\" .wide}"))
        #expect(MarkdownTable(source: table.markdown()) == table)

        table.columnWidths = [.auto, .auto, .auto]
        table.otherAttributes = []
        #expect(!table.markdown().contains("{"))
    }

    @Test func badWidthValuesFallBackToAuto() throws {
        let table = try #require(MarkdownTable(source: "| a | b |\n|---|---|\n{cols=\"wide,0\"}"))
        #expect(table.columnWidths == [.auto, .auto])
        #expect(table.rows.isEmpty)
        #expect(MarkdownTable.ColumnWidth("12.5%") == .percent(12.5))
        #expect(MarkdownTable.ColumnWidth("80px") == .points(80))
        #expect(MarkdownTable.ColumnWidth.percent(12.5).text == "12.5%")
    }

    @Test func structuralEditsCarryTheWidths() throws {
        var table = try #require(MarkdownTable(source: source))
        table.moveColumn(2, to: 0)
        #expect(table.columnWidths == [.points(120), .percent(30), .auto])
        table.insertColumn(at: 1)
        #expect(table.columnWidths == [.points(120), .auto, .percent(30), .auto])
        table.removeColumn(0)
        #expect(table.columnWidths == [.auto, .percent(30), .auto])
    }

    @Test func theAttributeLineBelongsToTheTableToken() {
        let doc = "Intro\n\n" + source + "\n\nOutro"
        let token = MarkdownTokenizer.parseTokensViaAST(in: doc).first { $0.kind == .table }
        let text = token.map { (doc as NSString).substring(with: $0.range) }
        #expect(text == source)
        // A plain paragraph after a table stays a paragraph.
        let plain = "| a |\n|---|\nnot attributes"
        let plainToken = MarkdownTokenizer.parseTokensViaAST(in: plain).first { $0.kind == .table }
        #expect(plainToken.map { (plain as NSString).substring(with: $0.range) } == "| a |\n|---|")
    }

    @Test func setColumnWidthKeepsTheUnit() throws {
        var table = try #require(MarkdownTable(source: source))
        table.setColumnWidth(0, to: 200, availableWidth: 400)
        #expect(table.columnWidths[0] == .percent(50))
        table.setColumnWidth(1, to: 90.4, availableWidth: 400)
        #expect(table.columnWidths[1] == .points(90))
        table.setColumnWidth(2, to: 1, availableWidth: 400)
        #expect(table.columnWidths[2] == .points(TableGridLayout.minColumnWidth))
    }

    // MARK: Layout

    private let font = PlatformFont.systemFont(ofSize: 14)

    private func layout(_ rows: [[String]], widths: [MarkdownTable.ColumnWidth] = [], available: CGFloat = 0) -> TableGridLayout {
        let cells = rows.map { $0.map { NSAttributedString(string: $0, attributes: [.font: font]) } }
        return TableGridLayout(cells: cells, columnCount: rows[0].count, baseFont: font, widths: widths, availableWidth: available)
    }

    @Test func layoutHonorsPointAndPercentWidths() {
        let l = layout([["a", "b"], ["1", "2"]], widths: [.points(150), .percent(50)], available: 400)
        #expect(abs(l.columnWidth(0) - 150) <= 1)
        #expect(abs(l.columnWidth(1) - 200) <= 1)
    }

    @Test func narrowFixedColumnsWrapAndGrowTheirRow() {
        let long = "a long cell that cannot fit in a narrow column at all"
        let auto = layout([["h", "h"], [long, "x"], ["y", "z"]])
        let fixed = layout([["h", "h"], [long, "x"], ["y", "z"]], widths: [.points(80)])
        #expect(fixed.rowHeight(1) > auto.rowHeight(1) * 2)
        #expect(fixed.rowHeight(2) == auto.rowHeight(2))
        #expect(fixed.columnWidth(0) < auto.columnWidth(0))
    }

    @Test func gutterSurroundsTheTable() {
        let l = layout([["a", "b"], ["1", "2"]])
        #expect(l.tableRect.minY == TableGridLayout.gutter.top)
        #expect(l.size.width == l.tableRect.maxX + TableGridLayout.gutter.right)
        #expect(l.size.height == l.tableRect.maxY + TableGridLayout.gutter.bottom)
        // The gutter isn't a cell.
        #expect(l.cell(at: CGPoint(x: l.tableRect.midX, y: 2)) == nil)
        #expect(l.cell(at: CGPoint(x: l.tableRect.maxX + 5, y: l.tableRect.midY)) == nil)
    }

    @Test func columnBordersAreFoundForResizing() {
        let l = layout([["a", "b"], ["1", "2"]])
        let y = l.tableRect.midY
        #expect(l.columnBorder(near: CGPoint(x: l.columnLeft[1] - 0.5, y: y)) == 1)
        #expect(l.columnBorder(near: CGPoint(x: l.tableRect.maxX - 1, y: y)) == 2)
        #expect(l.columnBorder(near: CGPoint(x: l.cellRect(row: 0, column: 0).midX, y: y)) == nil)
        #expect(l.columnBorder(near: CGPoint(x: l.columnLeft[1], y: 2)) == nil)   // in the gutter
    }

    // MARK: Markers

    @Test func hoverShowsHandlesAndNearbyInsertButtons() {
        let l = layout([["a", "b"], ["1", "2"], ["3", "4"]])
        let inCell = l.cellRect(row: 1, column: 1)
        let markers = l.visibleMarkers(pointer: CGPoint(x: inCell.midX, y: inCell.midY), editing: nil)
        #expect(Set(markers) == [.columnHandle(1), .rowHandle(1), .addRow, .addColumn])

        // Over the gutter at the border between the columns.
        let between = CGPoint(x: l.columnLeft[1], y: TableGridLayout.gutter.top / 2)
        let top = l.visibleMarkers(pointer: between, editing: nil)
        #expect(top.contains(.insertColumn(1)))
        #expect(l.marker(at: between, among: top) == .insertColumn(1))

        // At the left edge on the border between body rows 1 and 2.
        let edge = CGPoint(x: l.tableRect.minX + 6, y: l.rowTop[2])
        #expect(l.marker(at: edge, among: l.visibleMarkers(pointer: edge, editing: nil)) == .insertRow(2))

        #expect(l.visibleMarkers(pointer: nil, editing: nil).isEmpty)
        #expect(Set(l.visibleMarkers(pointer: nil, editing: (2, 0))) == [.columnHandle(0), .rowHandle(2), .addRow, .addColumn])
    }

    @Test func plusMarkersInsertAndFocusTheNewCell() throws {
        let l = layout([["a", "b"], ["1", "2"]])
        let table = try #require(MarkdownTable(source: "| a | b |\n|---|---|\n| 1 | 2 |"))
        let column = try #require(l.apply(.insertColumn(1), to: table))
        #expect(column.table.header == ["a", "", "b"] && column.focus == (0, 1))
        let row = try #require(l.apply(.addRow, to: table))
        #expect(row.table.rows.count == 2 && row.focus == (2, 0))
        let between = try #require(l.apply(.insertRow(1), to: table))
        #expect(between.table.rows == [["", ""], ["1", "2"]])
        let appended = try #require(l.apply(.addColumn, to: table))
        #expect(appended.table.header == ["a", "b", ""] && appended.focus == (0, 2))
        #expect(l.apply(.columnHandle(0), to: table) == nil)
    }

    // MARK: Handle menus

    private func run(_ groups: [[TableGridCommand]], _ title: String, on table: MarkdownTable) -> MarkdownTable? {
        guard let command = groups.joined().first(where: { $0.title == title }), command.isEnabled,
              case .edit(let edit) = command.action else { return nil }
        var t = table
        _ = edit(&t)
        return t
    }

    @Test func columnHandleCommands() throws {
        let table = try #require(MarkdownTable(source: source))
        let menu = table.columnCommands(0)
        #expect(run(menu, "Move Column Left", on: table) == nil)   // disabled
        #expect(run(menu, "Move Column Right", on: table)?.header == ["b", "a", "c"])
        let right = run(menu, "Align Right", on: table)
        #expect(right?.alignments.first == .right)
        #expect(right?.markdown().split(separator: "\n")[1].hasPrefix("| --") == true)
        #expect(run(menu, "Fit Width to Content", on: table)?.columnWidths == [.auto, .auto, .points(120)])
        #expect(run(menu, "Fit All Columns to Content", on: table)?.columnWidths == [.auto, .auto, .auto])
        #expect(run(menu, "Delete Column", on: table)?.header == ["b", "c"])
        #expect(run(menu, "Insert Column Left", on: table)?.header == ["", "a", "b", "c"])
    }

    @Test func rowHandleCommands() throws {
        let table = try #require(MarkdownTable(source: "| h |\n|---|\n| 1 |\n| 2 |"))
        #expect(run(table.rowCommands(0), "Delete Row", on: table) == nil)    // the header stays
        #expect(run(table.rowCommands(0), "Insert Row Below", on: table)?.rows == [[""], ["1"], ["2"]])
        #expect(run(table.rowCommands(1), "Move Row Down", on: table)?.rows == [["2"], ["1"]])
        #expect(run(table.rowCommands(1), "Move Row Up", on: table) == nil)
        #expect(run(table.rowCommands(2), "Move Row Up", on: table)?.rows == [["2"], ["1"]])
        #expect(run(table.rowCommands(2), "Delete Row", on: table)?.rows == [["1"]])
    }
}
