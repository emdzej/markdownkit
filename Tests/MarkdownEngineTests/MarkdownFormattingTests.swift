//
//  MarkdownFormattingTests.swift
//

import Foundation
import Testing
@testable import MarkdownEngineCore

@Suite("Formatting commands")
struct MarkdownFormattingTests {
    private func apply(_ edit: MarkdownFormattingEdit, to text: String) -> (String, NSRange) {
        ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    @Test func boldWrapsAndUnwrapsTheSelection() {
        let text = "make this bold"
        let wrapped = apply(MarkdownFormatting.toggle(.bold, in: text, selection: NSRange(location: 10, length: 4)), to: text)
        #expect(wrapped.0 == "make this **bold**")
        #expect(wrapped.1 == NSRange(location: 12, length: 4))
        let unwrapped = apply(MarkdownFormatting.toggle(.bold, in: wrapped.0, selection: wrapped.1), to: wrapped.0)
        #expect(unwrapped.0 == text)
        #expect(unwrapped.1 == NSRange(location: 10, length: 4))
    }

    @Test func caretInAWordWrapsTheWord() {
        let text = "a word here"
        let result = apply(MarkdownFormatting.toggle(.italic, in: text, selection: NSRange(location: 4, length: 0)), to: text)
        #expect(result.0 == "a *word* here")
        #expect(result.1 == NSRange(location: 5, length: 0))
    }

    @Test func caretOnSpaceInsertsAnEmptyPair() {
        let text = "a  b"
        let result = apply(MarkdownFormatting.toggle(.code, in: text, selection: NSRange(location: 2, length: 0)), to: text)
        #expect(result.0 == "a `` b")
        #expect(result.1 == NSRange(location: 3, length: 0))
    }

    @Test func italicDoesNotUnwrapBold() {
        let text = "**x**"
        let result = apply(MarkdownFormatting.toggle(.italic, in: text, selection: NSRange(location: 2, length: 1)), to: text)
        #expect(result.0 == "***x***")
    }

    @Test func selectionIncludingMarkersUnwraps() {
        let text = "~~gone~~"
        let result = apply(MarkdownFormatting.toggle(.strikethrough, in: text, selection: NSRange(location: 0, length: 8)), to: text)
        #expect(result.0 == "gone")
    }

    @Test func headingReplacesListPrefixAndToggles() {
        let text = "- item\nnext"
        let heading = apply(MarkdownFormatting.setBlock(.heading, in: text, selection: NSRange(location: 3, length: 0)), to: text)
        #expect(heading.0 == "## item\nnext")
        #expect(heading.1 == NSRange(location: 4, length: 0))
        let body = apply(MarkdownFormatting.setBlock(.heading, in: heading.0, selection: heading.1), to: heading.0)
        #expect(body.0 == "item\nnext")
    }

    @Test func numberedListNumbersEveryLine() {
        let text = "a\nb\nc"
        let result = apply(MarkdownFormatting.setBlock(.numbered, in: text, selection: NSRange(location: 0, length: 5)), to: text)
        #expect(result.0 == "1. a\n2. b\n3. c")
    }

    @Test func checklistKeepsIndentation() {
        let text = "\t- todo"
        let result = apply(MarkdownFormatting.setBlock(.task, in: text, selection: NSRange(location: 4, length: 0)), to: text)
        #expect(result.0 == "\t- [ ] todo")
        #expect(MarkdownFormatting.blockStyle(at: 3, in: result.0) == .task)
    }

    @Test func blockStyleDetection() {
        let text = "# T\n### S\n> q\n3. n\nplain"
        #expect(MarkdownFormatting.blockStyle(at: 1, in: text) == .title)
        #expect(MarkdownFormatting.blockStyle(at: 5, in: text) == .subheading)
        #expect(MarkdownFormatting.blockStyle(at: 11, in: text) == .quote)
        #expect(MarkdownFormatting.blockStyle(at: 15, in: text) == .numbered)
        #expect(MarkdownFormatting.blockStyle(at: 20, in: text) == .body)
    }

    @Test func indentAndOutdent() {
        let text = "- a\n- b"
        let indented = apply(MarkdownFormatting.indent(true, in: text, selection: NSRange(location: 0, length: 7)), to: text)
        #expect(indented.0 == "\t- a\n\t- b")
        let back = apply(MarkdownFormatting.indent(false, in: indented.0, selection: indented.1), to: indented.0)
        #expect(back.0 == text)
    }

    @Test func tableGoesOnItsOwnLines() {
        let text = "before"
        let result = apply(MarkdownFormatting.insertTable(in: text, selection: NSRange(location: 6, length: 0)), to: text)
        #expect(result.0 == "before\n\n|     |     |\n|-----|-----|\n|     |     |\n|     |     |\n\n")
        #expect(MarkdownTable(source: String(result.0.dropFirst(8)).trimmingCharacters(in: .newlines)) != nil)
        #expect(result.1.location == 10)
    }
}

@Suite("Table cell editing helpers")
@MainActor
struct TableCellEditingTests {
    @Test func columnNames() {
        #expect(MarkdownEditorController.columnName(0) == "A")
        #expect(MarkdownEditorController.columnName(25) == "Z")
        #expect(MarkdownEditorController.columnName(26) == "AA")
        #expect(MarkdownEditorController.TableCell(row: 2, column: 1).address == "B2")
        #expect(MarkdownEditorController.TableCell(row: 0, column: 1).address == nil)
    }

    #if os(iOS)
    @Test func formulaCellsAreEditedAsEqualsFormulas() {
        #expect(TableGridUIView.editableText("[?](#SUM(A1:A2))") == "=SUM(A1:A2)")
        #expect(TableGridUIView.editableText("total [?](#SUM(A1:A2))") == "total [?](#SUM(A1:A2))")
        #expect(TableGridUIView.editableText("plain") == "plain")
    }
    #endif
}
