//
//  FormulaTests.swift
//  MarkdownEngineTests
//
//  Formulas in tables; the first suite ports vitepress-plugin-markdownformula's tests.
//

import Foundation
import Testing
@testable import MarkdownEngineCore

private let table1 = """
<!-- table1 -->
| name           | formula         | values           |
| -------------- | --------------- | ---------------- |
| three          | -               | 3                |
| eight          | -               | 8                |
| summation      | #SUM(C1:C2)     | [?](#SUM(C1:C2)) |
| multiplication | #C1*C2          | [?](#C1*C2)      |
| average        | #AVERAGE(C1:C2) | [?](#AVERAGE(C1:C2)) |

"""

private func values(_ doc: String, _ options: MarkdownFormulas.Options = .init()) -> [String: String] {
    Dictionary(MarkdownFormulas.evaluate(document: doc, options: options).map { ($0.formula, $0.value) }, uniquingKeysWith: { a, _ in a })
}

/// The value of a single formula in a one-table document.
private func eval(_ formula: String, rows: String = "| 1 | 2 | 3 |\n| 4 | x |   |") -> String {
    let doc = "| a | b | c |\n| - | - | - |\n\(rows)\n| [?](#\(formula)) | | |\n"
    return MarkdownFormulas.evaluate(document: doc).first?.value ?? "<none>"
}

@Suite("Formulas: plugin compatibility")
struct FormulaPluginCompatibilityTests {

    @Test func evaluatesTheBasicExample() {
        let v = values(table1)
        #expect(v["SUM(C1:C2)"] == "11")
        #expect(v["C1*C2"] == "24")
        #expect(v["AVERAGE(C1:C2)"] == "5.5")
    }

    @Test func reportsSourceRanges() throws {
        let sum = try #require(MarkdownFormulas.evaluate(document: table1).first { $0.formula == "SUM(C1:C2)" })
        #expect((table1 as NSString).substring(with: sum.range) == "[?](#SUM(C1:C2))")
        #expect(sum.sheet == "table1")
        #expect(sum.cell == "C3")
    }

    @Test func noFormulasNoResults() {
        #expect(MarkdownFormulas.evaluate(document: "# Hello\n\nJust prose, no tables.\n").isEmpty)
    }

    @Test func formulasWithQuotesAndParentheses() {
        let doc = """
        <!-- t -->
        | a | b | c |
        | - | - | - |
        | 3 | x | [?](#COUNTIF(A1:A3,">3")) |
        | 8 | y | z |
        | 11 | z | w |
        """
        #expect(values(doc)["COUNTIF(A1:A3,\">3\")"] == "2")
    }

    @Test func errorsAreErrorCodes() throws {
        let doc = "<!-- e -->\n| a | b |\n| - | - |\n| 1 | [?](#A1/0) |\n"
        let result = try #require(MarkdownFormulas.evaluate(document: doc).first)
        #expect(result.value == "#DIV/0!")
        #expect(result.isError)
    }

    @Test func crossSheetReferences() {
        let doc = table1 + """

        <!-- table2 -->
        | name                  | value            |
        | --------------------- | ---------------- |
        | summation from table1 | [?](#table1!C3)  |

        """
        #expect(values(doc)["table1!C3"] == "11")
    }

    @Test func unnamedSheetsAreNumbered() {
        let doc = "| a |\n| - |\n| 5 |\n\ntext\n\n| b |\n| - |\n| [?](#Sheet0!A1*2) |\n"
        #expect(values(doc)["Sheet0!A1*2"] == "10")
    }

    @Test func headerCanCountAsRowOne() {
        let doc = "| 10 | b |\n| - | - |\n| 1 | [?](#A1+A2) |\n"
        #expect(values(doc)["A1+A2"] == "1")    // A1 is the first body row; A2 is past the table (blank)
        #expect(values(doc, .init(includeHeaderInCellEnumeration: true))["A1+A2"] == "11")
    }

    @Test func roundsLikeHyperFormula() {
        #expect(eval("1/3") == "0.33333")
        #expect(eval("2/3") == "0.66667")
        #expect(eval("100/3") == "33.333")
        #expect(eval("0.1+0.2") == "0.3")
        #expect(FormulaEvaluator.round(123456.789, precision: 4) == 123460)
    }
}

@Suite("Formulas: evaluator")
struct FormulaEvaluatorTests {

    @Test func arithmeticAndPrecedence() {
        #expect(eval("1+2*3") == "7")
        #expect(eval("(1+2)*3") == "9")
        #expect(eval("-2^2") == "4")
        #expect(eval("2^3^2") == "64")
        #expect(eval("50%*10") == "5")
        #expect(eval("10-2-3") == "5")
        #expect(eval("\"a\"&1+1") == "a2")
    }

    @Test func comparisonsAndBooleans() {
        #expect(eval("1<2") == "TRUE")
        #expect(eval("\"a\"=\"A\"") == "TRUE")
        #expect(eval("1<>1") == "FALSE")
        #expect(eval("IF(A1>0,\"pos\",\"neg\")") == "pos")
        #expect(eval("AND(TRUE,A1)") == "TRUE")
        #expect(eval("OR(FALSE,0)") == "FALSE")
        #expect(eval("NOT(A1)") == "FALSE")
    }

    @Test func aggregatesSkipTextInRanges() {
        // A1:C2 = 1 2 3 / 4 x _
        #expect(eval("SUM(A1:C2)") == "10")
        #expect(eval("COUNT(A1:C2)") == "4")
        #expect(eval("COUNTA(A1:C2)") == "5")
        #expect(eval("AVERAGE(A1:C2)") == "2.5")
        #expect(eval("MIN(A1:C2)") == "1")
        #expect(eval("MAX(A1:C2)") == "4")
        #expect(eval("PRODUCT(A1:C2)") == "24")
        #expect(eval("SUM(B2)") == "0")
        #expect(eval("SUM(\"x\")") == "#VALUE!")
        #expect(eval("A1+B2") == "#VALUE!")
    }

    @Test func mathFunctions() {
        #expect(eval("ROUND(2.675,2)") == "2.68")
        #expect(eval("ROUND(-2.5)") == "-3")
        #expect(eval("ROUNDUP(1.21,1)") == "1.3")
        #expect(eval("ROUNDDOWN(-1.29,1)") == "-1.2")
        #expect(eval("ABS(-4)") == "4")
        #expect(eval("SQRT(16)") == "4")
        #expect(eval("SQRT(-1)") == "#NUM!")
        #expect(eval("POWER(2,10)") == "1024")
        #expect(eval("MOD(-3,2)") == "1")
        #expect(eval("MOD(1,0)") == "#DIV/0!")
        #expect(eval("INT(-1.5)") == "-2")
    }

    @Test func conditionalAggregates() {
        let rows = "| apple | 3 | |\n| pear | 5 | |\n| apricot | 7 | |"
        #expect(eval("COUNTIF(A1:A3,\"ap*\")", rows: rows) == "2")
        #expect(eval("SUMIF(A1:A3,\"ap*\",B1:B3)", rows: rows) == "10")
        #expect(eval("AVERAGEIF(B1:B3,\">4\")", rows: rows) == "6")
        #expect(eval("COUNTIF(B1:B3,5)", rows: rows) == "1")
        #expect(eval("COUNTIF(A1:A3,\"<>pear\")", rows: rows) == "2")
        #expect(eval("SUMIF(B1:B3,\">=5\")", rows: rows) == "12")
    }

    @Test func textFunctions() {
        #expect(eval("CONCAT(\"a\",A1:B1)") == "a12")
        #expect(eval("CONCATENATE(\"x\",\"-\",1.5)") == "x-1.5")
        #expect(eval("LEN(\"hello\")") == "5")
        #expect(eval("UPPER(\"abc\")") == "ABC")
        #expect(eval("LOWER(B2)") == "x")
        #expect(eval("TRIM(\"  a   b \")") == "a b")
        #expect(eval("LEFT(\"hello\",2)") == "he")
        #expect(eval("RIGHT(\"hello\")") == "o")
        #expect(eval("MID(\"hello\",2,3)") == "ell")
    }

    @Test func errors() {
        #expect(eval("NOPE(1)") == "#NAME?")
        #expect(eval("missing!A1") == "#REF!")
        #expect(eval("IFERROR(1/0,\"none\")") == "none")
        #expect(eval("IFERROR(5,0)") == "5")
        #expect(eval("A1:B2") == "#VALUE!")
        #expect(eval("Z99") == "0")     // outside the table: empty, as in a spreadsheet
    }

    @Test func formulaCellsReferenceEachOtherAndCyclesAreCaught() {
        let doc = """
        | a | b |
        | - | - |
        | [?](#B1*2) | 4 |
        | [?](#A1+1) | [?](#B2) |
        """
        let v = values(doc)
        #expect(v["B1*2"] == "8")
        #expect(v["A1+1"] == "9")
        #expect(v["B2"] == "#CYCLE!")
    }

    @Test func headingAnchorsAreNotFormulas() {
        let doc = "| a |\n| - |\n| [see](#intro) |\n| [x](#my-heading) |\n| [ok](#A1) |\n"
        #expect(MarkdownFormulas.evaluate(document: doc).map(\.formula) == ["A1"])
        #expect(MarkdownFormulas.formula(inCell: "[see](#intro)") == nil)
        #expect(MarkdownFormulas.formula(inCell: "[?](#SUM(A1:A2))") == "SUM(A1:A2)")
    }

    @Test func typedEqualsBecomesAFormulaLink() {
        #expect(MarkdownFormulas.cellSource(fromTyped: "=SUM(A1:A2)") == "[?](#SUM(A1:A2))")
        #expect(MarkdownFormulas.cellSource(fromTyped: " =A1*2 ") == "[?](#A1*2)")
        #expect(MarkdownFormulas.cellSource(fromTyped: "=") == "=")
        #expect(MarkdownFormulas.cellSource(fromTyped: "= not a formula ((") == "= not a formula ((")
        #expect(MarkdownFormulas.cellSource(fromTyped: "plain") == "plain")
    }

    @Test func sheetNamesWithSpacesNeedQuotes() {
        let doc = "<!-- my table -->\n| a |\n| - |\n| 2 |\n\n| b |\n| - |\n| [?](#'my table'!A1*3) |\n"
        #expect(values(doc)["'my table'!A1*3"] == "6")
    }

    @Test func numberFormatting() {
        #expect(FormulaEvaluator.format(11) == "11")
        #expect(FormulaEvaluator.format(5.5) == "5.5")
        #expect(FormulaEvaluator.format(-0.25) == "-0.25")
        #expect(FormulaEvaluator.format(0.00001) == "0.00001")
        #expect(FormulaEvaluator.format(1e21) == "1e+21")
    }
}

#if os(macOS)
import AppKit
#endif

@Suite("Formulas: rendering")
struct FormulaRenderingTests {

    private func styled(_ text: String, caret: Int, mode: RenderingMode = .formatted) -> [StyledRange] {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        var configuration = MarkdownEditorConfiguration.default
        configuration.renderingMode = mode
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caret, length: 0), tokens: tokens, in: text as NSString)
        return MarkdownStyler.styleAttributes(
            text: text, fontName: "Helvetica", fontSize: 14,
            caretLocation: caret, activeTokenIndices: active,
            precomputedTokens: tokens, configuration: configuration
        )
    }

    @Test func gridCellsShowValuesAndKeepTheirFormulas() throws {
        let doc = table1 + "\nEnd\n"
        let attrs = styled(doc, caret: (doc as NSString).length)
        let info = try #require(attrs.lazy.compactMap { $0.1[.tableRenderInfo] as? TableRenderInfo }.first)
        // Body rows 3–5 (grid rows 3…5), column C.
        #expect(info.formula(row: 3, column: 2) == "SUM(C1:C2)")
        #expect(info.formula(row: 4, column: 2) == "C1*C2")
        #expect(info.formula(row: 5, column: 2) == "AVERAGE(C1:C2)")
        #expect(info.formula(row: 1, column: 2) == nil)
        // The `#SUM(C1:C2)` text in column B is just text.
        #expect(info.formula(row: 3, column: 1) == nil)
        // The model (what the cell editor shows) keeps the link.
        #expect(info.table.rows[2][2] == "[?](#SUM(C1:C2))")
    }

    @Test func cellStringReplacesOnlyTheLink() {
        let result = MarkdownFormulas.FormulaResult(range: NSRange(), formula: "1+1", value: "2", isError: false, sheet: "Sheet0", cell: "A1")
        let string = MarkdownStyler.formulaCellString(
            "Total: [?](#1+1) €", result: result, baseFont: .systemFont(ofSize: 14),
            theme: .default, codeBackgroundColor: .clear, latex: MarkdownEditorConfiguration.default.services.latex)
        #expect(string.string == "Total: 2 €")
        let error = MarkdownFormulas.FormulaResult(range: NSRange(), formula: "1/0", value: "#DIV/0!", isError: true, sheet: "Sheet0", cell: "A1")
        let errorString = MarkdownStyler.formulaCellString(
            "[?](#1/0)", result: error, baseFont: .systemFont(ofSize: 14),
            theme: .default, codeBackgroundColor: .clear, latex: MarkdownEditorConfiguration.default.services.latex)
        #expect(errorString.string == "#DIV/0!")
    }

    @Test func otherFormulaTablesAreRestyledAfterAnEdit() {
        let doc = table1 + "\n<!-- table2 -->\n| n | v |\n| - | - |\n| s | [?](#table1!C3) |\n\n| plain |\n| - |\n| 1 |\n"
        let ns = doc as NSString
        let first = ns.range(of: "| name")
        let dependents = MarkdownFormulas.dependentTableParagraphs(in: doc, excluding: NSRange(location: first.location, length: 10))
        #expect(dependents.count == 1)
        #expect(ns.substring(with: dependents[0]).contains("table1!C3"))
    }

    @Test func sourceModeColorsFormulaDestinations() throws {
        let doc = "| a |\n| - |\n| [?](#SUM(A1:A2)) |\n| [x](#intro) |\n"
        let attrs = styled(doc, caret: 0, mode: .source)
        let ns = doc as NSString
        let formula = ns.range(of: "SUM(A1:A2)")
        let anchor = ns.range(of: "intro")
        let color = { (location: Int) in
            attrs.last { NSLocationInRange(location, $0.range) && $0.attributes[.foregroundColor] != nil }?.attributes[.foregroundColor] as? PlatformColor
        }
        #expect(color(formula.location) == SourceModeStyle.default.codeColor)
        #expect(color(anchor.location) != SourceModeStyle.default.codeColor)
    }
}
