#if os(macOS)
//
//  NativeTextViewCoordinator+Tables.swift
//  MarkdownEngine
//
//  Table-grid policy: tables stay rendered (and edited through
//  `TableGridView`) unless the user picked "Edit as Markdown" for one, and a
//  caret that lands in a table's hidden source is handed to the grid.
//

import AppKit

extension NativeTextViewCoordinator {

    var tableRevealPolicy: MarkdownDetection.TableRevealPolicy {
        MarkdownStyler.tableGridSupported && configuration.renderingMode == .formatted ? .only(revealedTableLocation) : .caret
    }

    /// The table token whose lines contain `location` (end of its last line included).
    func tableToken(containing location: Int, in text: String) -> MarkdownToken? {
        parsedDocument(for: text).tokens.first { token in
            token.kind == .table
                && location >= token.range.location
                && location <= NSMaxRange(token.range)
        }
    }

    /// Shows the table starting at `location` as raw markdown and puts the caret in it.
    func revealTableSource(at location: Int, in textView: NativeTextView) {
        revealedTableLocation = location
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        if let token = tableToken(containing: location, in: textView.string) {
            restyleParagraphs([(textView.string as NSString).paragraphRange(for: token.range)], in: textView)
        }
    }

    /// Called on every selection change before restyling. Returns true when it
    /// moved focus into a table grid (the caller should stop processing).
    func routeSelectionThroughTableGrid(_ textView: NSTextView) -> Bool {
        guard MarkdownStyler.tableGridSupported, configuration.renderingMode == .formatted,
              let native = textView as? NativeTextView else { return false }
        let selection = textView.selectedRange()
        let table = tableToken(containing: selection.location, in: textView.string)

        // Leaving the revealed table turns it back into a grid.
        if let revealed = revealedTableLocation, table?.range.location != revealed {
            revealedTableLocation = nil
            let ns = textView.string as NSString
            if revealed < ns.length {
                restyleParagraphs([ns.paragraphRange(for: NSRange(location: revealed, length: 0))], in: textView)
            }
        }

        // Only a caret the user is moving in the text view enters a grid.
        guard textView.window?.firstResponder === textView, let table, selection.length == 0,
              table.range.location != revealedTableLocation else { return false }
        // Coming from below → last row, otherwise → first row.
        let fromBelow = (previousCaretLocation ?? 0) > NSMaxRange(table.range)
        let row = fromBelow ? max(0, (MarkdownTable(source: (textView.string as NSString).substring(with: table.range))?.rowCount ?? 1) - 1) : 0
        return native.focusTableCell(tableLocation: table.range.location, row: row, column: 0)
    }
}
#endif
