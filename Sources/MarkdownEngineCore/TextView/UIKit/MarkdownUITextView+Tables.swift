#if os(iOS) || os(visionOS)
//
//  MarkdownUITextView+Tables.swift
//  MarkdownEngine
//
//  Text-view side of the UIKit table grid: overlay reconciliation, writing
//  an edited table back (one undoable edit), restoring cell focus after the
//  re-render, and moving the caret out of a table.
//

import UIKit

extension MarkdownUITextView {

    var markdownCoordinator: MarkdownUICoordinator? { delegate as? MarkdownUICoordinator }

    // MARK: Overlays

    /// Coalesces overlay updates to once per runloop turn, after layout settles.
    func updateTableOverlays() {
        guard !pendingTableOverlayUpdate else { return }
        pendingTableOverlayUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingTableOverlayUpdate = false
            self.performTableOverlayUpdate()
        }
    }

    /// Creates, positions, and removes overlays to match the `.tableRenderInfo` attributes.
    func performTableOverlayUpdate() {
        guard let bridge = layoutBridge, let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else { return }
        let storage = textStorage
        let full = NSRange(location: 0, length: storage.length)
        let columnWidth = bounds.width - textContainerInset.left - textContainerInset.right
        guard columnWidth > 0 else { return }

        var seen: Set<Int> = []
        storage.enumerateAttribute(.scrollableBlockSourceID, in: full) { value, anchor, _ in
            guard let sourceID = value as? Int,
                  let info = storage.attribute(.tableRenderInfo, at: anchor.location, effectiveRange: nil) as? TableRenderInfo
            else { return }
            seen.insert(sourceID)

            if let start = tcs.location(tcs.documentRange.location, offsetBy: anchor.location),
               let end = tcs.location(start, offsetBy: anchor.length),
               let range = NSTextRange(location: start, end: end) {
                tlm.ensureLayout(for: range)
            }
            let anchorRect = bridge.boundingRect(forCharacterRange: anchor, in: textContainer)
            guard !anchorRect.isEmpty else { return }
            let height = (storage.attribute(.scrollableBlockTotalHeight, at: anchor.location, effectiveRange: nil) as? CGFloat)
                ?? info.layout.size.height
            let frame = CGRect(
                x: textContainerInset.left + anchorRect.minX,
                y: textContainerInset.top + anchorRect.minY,
                width: columnWidth - anchorRect.minX,
                height: height
            )

            // An edited table gets a new sourceID; keep its overlay by start location.
            if tableOverlays[sourceID] == nil,
               let (oldID, moved) = tableOverlays.first(where: {
                   !seen.contains($0.key) && $0.value.tableLocation == info.sourceRange.location
               }) {
                tableOverlays.removeValue(forKey: oldID)
                moved.sourceID = sourceID
                tableOverlays[sourceID] = moved
            }
            if let overlay = tableOverlays[sourceID] {
                overlay.frame = frame
                overlay.update(info: info)
            } else {
                let overlay = TableOverlayUIView(sourceID: sourceID, info: info, textView: self)
                overlay.frame = frame
                addSubview(overlay)
                tableOverlays[sourceID] = overlay
            }
        }
        for (id, overlay) in tableOverlays where !seen.contains(id) {
            overlay.removeFromSuperview()
            tableOverlays.removeValue(forKey: id)
        }
        applyPendingTableFocus()
        // The keeper only bridges a cell change; never leave the keyboard
        // attached to it once there is no cell left to focus.
        if pendingTableFocus == nil, keyboardKeeper.isFirstResponder {
            keyboardKeeper.resignFirstResponder()
        }
    }

    func removeAllTableOverlays() {
        tableOverlays.values.forEach { $0.removeFromSuperview() }
        tableOverlays.removeAll()
    }

    // MARK: Editing

    /// Replaces the table source at `range` with `table`'s markdown as one
    /// undoable edit, then (optionally) re-enters the grid at `focus`.
    func replaceTable(at range: NSRange, with table: MarkdownTable, actionName: String, focus: (row: Int, column: Int)?) {
        guard NSMaxRange(range) <= (string as NSString).length else { return }
        if let focus {
            pendingTableFocus = TableCellFocus(tableLocation: range.location, row: focus.row, column: focus.column)
        }
        let markdown = table.markdown()
        mdReplace(range, with: markdown)
        undoManager?.setActionName(actionName)
        markdownCoordinator?.programmaticEditDidChange(in: self, range: NSRange(location: range.location, length: (markdown as NSString).length))
    }

    @discardableResult
    func focusTableCell(tableLocation: Int, row: Int, column: Int) -> Bool {
        guard let overlay = tableOverlays.values.first(where: { $0.tableLocation == tableLocation }) else { return false }
        overlay.gridView.beginEditing(row: row, column: column)
        return true
    }

    func applyPendingTableFocus() {
        guard let focus = pendingTableFocus else { return }
        if focusTableCell(tableLocation: focus.tableLocation, row: focus.row, column: focus.column) {
            pendingTableFocus = nil
        }
    }

    /// Caret just above (end of the previous line) or below the table at `range`.
    func exitTable(range: NSRange, below: Bool) {
        let ns = string as NSString
        becomeFirstResponder()
        if below {
            let end = NSMaxRange(range)
            if end >= ns.length { mdReplace(NSRange(location: ns.length, length: 0), with: "\n") }
            selectedRange = NSRange(location: end + 1, length: 0)
        } else if range.location > 0 {
            selectedRange = NSRange(location: range.location - 1, length: 0)
        } else {
            mdReplace(NSRange(location: 0, length: 0), with: "\n")
            selectedRange = NSRange(location: 0, length: 0)
        }
        markdownCoordinator?.textChanged(self)
        scrollRangeToVisible(selectedRange)
    }

    /// Keeps the software keyboard up across a cell change: a hidden field
    /// holds first responder until the next cell's field takes over.
    func holdKeyboard() {
        if keyboardKeeper.superview == nil { addSubview(keyboardKeeper) }
        keyboardKeeper.becomeFirstResponder()
    }
}
#endif
