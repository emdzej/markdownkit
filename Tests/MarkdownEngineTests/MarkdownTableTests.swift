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
