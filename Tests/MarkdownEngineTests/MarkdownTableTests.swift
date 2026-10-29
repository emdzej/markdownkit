//
//  MarkdownTableTests.swift
//  MarkdownEngineTests
//

import Testing
@testable import MarkdownEngineCore

@Suite("MarkdownTable model")
struct MarkdownTableTests {

    @Test func parsesHeaderAlignmentAndRows() throws {
        let t = try #require(MarkdownTable(source: """
        | Name | Kind | Done |
        |:-----|:----:|-----:|
        | Parser | core | yes |
        """))
        #expect(t.header == ["Name", "Kind", "Done"])
        #expect(t.alignments == [.left, .center, .right])
        #expect(t.rows == [["Parser", "core", "yes"]])
    }

    @Test func leadingAndTrailingPipesAreOptional() throws {
        let t = try #require(MarkdownTable(source: "a | b\n--- | ---\n1 | 2"))
        #expect(t.header == ["a", "b"])
        #expect(t.alignments == [.none, .none])
        #expect(t.rows == [["1", "2"]])
    }

    @Test func rejectsMissingDelimiterRow() {
        #expect(MarkdownTable(source: "| a | b |\n| 1 | 2 |") == nil)
        #expect(MarkdownTable(source: "| a |") == nil)
    }

    @Test func bodyRowsArePaddedAndTruncatedToHeaderWidth() throws {
        let t = try #require(MarkdownTable(source: "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |"))
        #expect(t.rows == [["1", ""], ["1", "2"]])
    }

    @Test func escapedPipesRoundTrip() throws {
        let t = try #require(MarkdownTable(source: "| a \\| b | c |\n|---|---|\n| `x \\| y` | \\* |"))
        #expect(t.header == ["a | b", "c"])
        // Non-pipe escapes are kept for the inline parser.
        #expect(t.rows == [["`x | y`", "\\*"]])
        #expect(MarkdownTable(source: t.markdown()) == t)
    }

    @Test func serializesWithAlignedColumns() {
        let t = MarkdownTable(
            header: ["Name", "N"],
            alignments: [.left, .right],
            rows: [["Parser", "1"], ["UI", "12"]]
        )
        #expect(t.markdown() == """
        | Name   |   N |
        | :----- | --: |
        | Parser |   1 |
        | UI     |  12 |
        """)
    }

    @Test func centerAlignmentPadsBothSides() {
        let t = MarkdownTable(header: ["abcde"], alignments: [.center], rows: [["a"]])
        #expect(t.markdown() == "| abcde |\n| :---: |\n|   a   |")
    }

    @Test func pipesAndNewlinesInCellsAreEscaped() throws {
        var t = MarkdownTable(header: ["h"], alignments: [.none], rows: [[""]])
        t[1, 0] = "a|b\nc"
        #expect(t.markdown().hasSuffix("| a\\|b<br>c |"))
        #expect(try #require(MarkdownTable(source: t.markdown()))[1, 0] == "a|b<br>c")
    }

    @Test func rowEdits() {
        var t = MarkdownTable(header: ["a"], alignments: [.none], rows: [["1"], ["2"]])
        t.insertRow(at: 1)
        #expect(t.rows == [[""], ["1"], ["2"]])
        t.removeRow(1)
        t.moveRow(2, to: 1)
        #expect(t.rows == [["2"], ["1"]])
        t.removeRow(0)   // header can't be removed
        #expect(t.rowCount == 3)
    }

    @Test func columnEdits() {
        var t = MarkdownTable(header: ["a", "b"], alignments: [.left, .right], rows: [["1", "2"]])
        t.insertColumn(at: 1, alignment: .center)
        #expect(t.header == ["a", "", "b"])
        #expect(t.alignments == [.left, .center, .right])
        #expect(t.rows == [["1", "", "2"]])
        t.moveColumn(2, to: 0)
        #expect(t.header == ["b", "a", ""])
        t.removeColumn(2)
        t.removeColumn(1)
        t.removeColumn(0)   // last column stays
        #expect(t.header == ["b"])
        #expect(t.rows == [["2"]])
    }

    @Test func subscriptAddressesHeaderAsRowZero() {
        var t = MarkdownTable(header: ["h"], alignments: [.none], rows: [["b"]])
        t[0, 0] = "H"
        t[1, 0] = "B"
        #expect(t.header == ["H"])
        #expect(t.rows == [["B"]])
    }
}

@Suite("Table grid navigation")
struct TableGridNavigationTests {
    private let t = MarkdownTable(header: ["a", "b"], alignments: [.none, .none], rows: [["1", "2"]])

    @Test func tabWrapsAndGrowsAtTheEnd() {
        #expect(t.outcome(of: .next, fromRow: 0, column: 0) == .focus(table: t, row: 0, column: 1, actionName: "Edit Table"))
        #expect(t.outcome(of: .next, fromRow: 0, column: 1) == .focus(table: t, row: 1, column: 0, actionName: "Edit Table"))
        guard case .focus(let grown, 2, 0, "Add Row") = t.outcome(of: .next, fromRow: 1, column: 1) else {
            Issue.record("Tab past the last cell should add a row"); return
        }
        #expect(grown.rows == [["1", "2"], ["", ""]])
    }

    @Test func shiftTabStopsAtTheFirstCell() {
        #expect(t.outcome(of: .previous, fromRow: 1, column: 0) == .focus(table: t, row: 0, column: 1, actionName: "Edit Table"))
        #expect(t.outcome(of: .previous, fromRow: 0, column: 0) == .stay)
    }

    @Test func arrowsLeaveAtTheEdges() {
        #expect(t.outcome(of: .up, fromRow: 0, column: 1) == .exit(table: t, below: false))
        #expect(t.outcome(of: .down, fromRow: 1, column: 1) == .exit(table: t, below: true))
        #expect(t.outcome(of: .down, fromRow: 0, column: 1) == .focus(table: t, row: 1, column: 1, actionName: "Edit Table"))
    }

    @Test func returnInTheLastRowAddsARowInTheSameColumn() {
        guard case .focus(let grown, 2, 1, "Add Row") = t.outcome(of: .newline, fromRow: 1, column: 1) else {
            Issue.record("Return in the last row should add a row"); return
        }
        #expect(grown.rowCount == 3)
    }

    @Test func contextCommandsRespectTheHeaderAndLastColumn() {
        let flat = t.contextCommands(row: 0, column: 0).flatMap { $0 }
        func enabled(_ title: String) -> Bool? { flat.first { $0.title == title }?.isEnabled }
        #expect(enabled("Delete Row") == false)        // header row
        #expect(enabled("Insert Row Above") == false)
        #expect(enabled("Move Column Left") == false)
        #expect(enabled("Delete Column") == true)
        #expect(flat.first { $0.title == "Align Left" }?.isChecked == true)   // .none renders left
    }
}
