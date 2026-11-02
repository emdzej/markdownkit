#if os(macOS)
//
//  NativeTextView+Tables.swift
//  MarkdownEngine
//
//  Text-view side of the table grid: writing an edited table back into the
//  document (one undoable edit), restoring cell focus after the re-render,
//  and moving the caret out of a table.
//

import AppKit

extension NativeTextView {

    var coordinator: NativeTextViewCoordinator? { delegate as? NativeTextViewCoordinator }

    /// Replaces the table source at `range` with `table`'s markdown as one
    /// undoable edit, then (optionally) re-enters the grid at `focus`.
    func replaceTable(at range: NSRange, with table: MarkdownTable, actionName: String, focus: (row: Int, column: Int)?) {
        let length = (string as NSString).length
        guard NSMaxRange(range) <= length else { return }
        if let focus {
            pendingTableFocus = TableCellFocus(tableLocation: range.location, row: focus.row, column: focus.column)
        }
        let markdown = table.markdown()
        breakUndoCoalescing()
        mdReplace(range, with: markdown)
        undoManager?.setActionName(EngineStrings.localized(actionName))
        breakUndoCoalescing()
        restyleTable(at: NSRange(location: range.location, length: (markdown as NSString).length))
    }

    /// Re-renders the table at `range` and its overlay. A programmatic replace
    /// leaves no edited range for `textDidChange` to scope its restyle to.
    func restyleTable(at range: NSRange) {
        let ns = string as NSString
        guard NSMaxRange(range) <= ns.length else { return }
        // Formulas in other tables may read this one.
        let dependents = MarkdownFormulas.dependentTableParagraphs(in: string, excluding: range)
        coordinator?.restyleParagraphs([ns.paragraphRange(for: range)] + dependents, in: self)
        updateWideTableOverlays()
    }

    /// Starts editing a cell of the table at `tableLocation`. Returns false if
    /// that table has no grid on screen (yet).
    @discardableResult
    func focusTableCell(tableLocation: Int, row: Int, column: Int) -> Bool {
        guard let overlay = wideTableOverlays.values.first(where: { $0.tableLocation == tableLocation }) else {
            return false
        }
        overlay.gridView.beginEditing(row: row, column: column)
        return true
    }

    /// Applies `pendingTableFocus` once the overlays reflect the new source.
    func applyPendingTableFocus() {
        guard let focus = pendingTableFocus else { return }
        if focusTableCell(tableLocation: focus.tableLocation, row: focus.row, column: focus.column) {
            pendingTableFocus = nil
        }
    }

    /// Moves the caret just before (end of the previous line) or after the
    /// table at `range` and gives focus back to the text view. Leaving below
    /// a table that ends the document appends a newline so there is a line
    /// to land on.
    func exitTable(range: NSRange, below: Bool) {
        let ns = string as NSString
        window?.makeFirstResponder(self)
        if below {
            let end = NSMaxRange(range)
            if end >= ns.length {
                mdReplace(NSRange(location: ns.length, length: 0), with: "\n")
            }
            setSelectedRange(NSRange(location: end + 1, length: 0))
        } else if range.location > 0 {
            setSelectedRange(NSRange(location: range.location - 1, length: 0))
        } else {
            // Table opens the document: make room above it.
            mdReplace(NSRange(location: 0, length: 0), with: "\n")
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }
}
#endif
