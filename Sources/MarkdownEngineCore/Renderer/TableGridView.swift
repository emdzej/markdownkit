#if os(macOS)
//
//  TableGridView.swift
//  MarkdownEngine
//
//  WYSIWYG table editing. Draws the rendered table and edits one cell at a
//  time in an inline field that shows the cell's raw inline markdown
//  (the same raw-while-editing blend as the rest of the editor). Committing
//  a cell, or any structural change from the context menu, rewrites the
//  table's source as a single undoable edit via `NativeTextView.replaceTable`.
//
//  Markers (see `TableGridMarkers`) appear with the pointer: handles above
//  columns and left of rows open their menus, "+" buttons on the borders
//  insert there, and the bars below and right add a row / column. Dragging
//  a column border sets that column's width (`{cols="…"}` after the
//  table); double-clicking it fits the column to its content again.
//
//  Keys while editing a cell:
//    Tab / Shift-Tab   next / previous cell (Tab past the last cell adds a row)
//    Return            cell below (adds a row from the last row)
//    Up / Down         cell above / below; leaves the table at its edges
//    Esc               discard the cell's changes and leave the table
//

import AppKit

final class TableGridView: NSView, NSTextFieldDelegate, NSViewToolTipOwner {

    private(set) var info: TableRenderInfo
    weak var textView: NativeTextView?

    private var field: TableCellField?
    private(set) var editingCell: (row: Int, column: Int)?
    /// Set while focus moves programmatically, so end-of-editing doesn't commit twice.
    private var isFinishingEdit = false
    /// Pointer position while it's over the grid (drives the markers).
    private var pointer: CGPoint?
    /// A column border being dragged: the column left of it and the new right edge.
    private var resizing: (column: Int, edge: CGFloat)?
    private var hoverTracking: NSTrackingArea?

    init(info: TableRenderInfo, textView: NativeTextView) {
        self.info = info
        self.textView = textView
        super.init(frame: CGRect(origin: .zero, size: info.layout.size))
        updateFormulaToolTips()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func update(info: TableRenderInfo) {
        self.info = info
        setFrameSize(info.layout.size)
        updateFormulaToolTips()
        window?.invalidateCursorRects(for: self)
        if let editingCell, editingCell.row < info.table.rowCount, editingCell.column < info.table.columnCount {
            positionField(for: editingCell)
        }
        needsDisplay = true
    }

    // MARK: Formula tooltips

    /// Hovering a computed cell shows its formula.
    private func updateFormulaToolTips() {
        removeAllToolTips()
        for (row, columns) in info.formulas.enumerated() {
            for (column, formula) in columns.enumerated() where formula != nil {
                addToolTip(info.layout.cellRect(row: row, column: column), owner: self, userData: nil)
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        for (row, columns) in info.formulas.enumerated() {
            for (column, formula) in columns.enumerated() {
                if let formula, info.layout.cellRect(row: row, column: column).contains(point) { return "=" + formula }
            }
        }
        return ""
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        info.image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let cell = editingCell {
            NSColor.controlAccentColor.setStroke()
            // A field grown past its cell gets the ring around its full width.
            var box = info.layout.cellRect(row: cell.row, column: cell.column)
            if let field { box = box.union(CGRect(x: field.frame.minX, y: box.minY, width: field.frame.width, height: box.height)) }
            let ring = NSBezierPath(rect: box.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
        drawMarkers()
    }

    private var visibleMarkers: [TableGridMarker] {
        guard resizing == nil, textView?.isEditable ?? false else { return [] }
        return info.layout.visibleMarkers(pointer: pointer, editing: editingCell)
    }

    private func drawMarkers() {
        let layout = info.layout
        let accent = textView?.configuration.theme.link ?? .controlAccentColor
        let muted = textView?.configuration.theme.mutedText ?? .secondaryLabelColor
        if let resizing {
            // Guide at the dragged edge.
            accent.setFill()
            NSRect(x: resizing.edge - 1, y: layout.tableRect.minY, width: 2, height: layout.tableRect.height).fill()
            return
        }
        let markers = visibleMarkers
        let hot = pointer.flatMap { layout.marker(at: $0, among: markers) }
        layout.drawMarkers(markers, highlighted: hot, accent: accent, muted: muted)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        let layout = info.layout
        guard textView?.isEditable ?? false else { return }
        for i in 1...layout.columnCount {
            let x = layout.columnLeft[i] - TableGridLayout.borderWidth / 2
            addCursorRect(NSRect(x: x - 3, y: layout.tableRect.minY, width: 6, height: layout.tableRect.height), cursor: .resizeLeftRight)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layout = info.layout
        if let marker = layout.marker(at: point, among: visibleMarkers) {
            press(marker, at: point)
            return
        }
        if textView?.isEditable ?? false, let border = layout.columnBorder(near: point) {
            if event.clickCount == 2 {
                var table = tableWithFieldValue()
                table.columnWidths[border - 1] = .auto
                commitAndMove(to: nil, table: table, actionName: "Fit Column Width")
            } else {
                dragBorder(border, from: event)
            }
            return
        }
        guard let cell = layout.cell(at: point) else { return }
        if let editingCell, editingCell == cell { return }
        commitAndMove(to: cell)
    }

    private func press(_ marker: TableGridMarker, at point: CGPoint) {
        switch marker {
        case .columnHandle(let c):
            popUp(info.table.columnCommands(c), below: info.layout.rect(for: marker))
        case .rowHandle(let r):
            popUp(info.table.rowCommands(r), below: info.layout.rect(for: marker))
        default:
            guard let result = info.layout.apply(marker, to: tableWithFieldValue()) else { return }
            commitAndMove(to: result.focus, table: result.table, actionName: result.actionName)
        }
    }

    private func popUp(_ groups: [[TableGridCommand]], below rect: CGRect) {
        let menu = menu(for: groups)
        menu.popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.maxY + 4), in: self)
    }

    /// Follows the drag of column border `border` (right edge of column
    /// `border - 1`) and writes the new width on release.
    private func dragBorder(_ border: Int, from event: NSEvent) {
        let column = border - 1
        let left = info.layout.columnLeft[column]
        let minEdge = left + TableGridLayout.minColumnWidth
        var edge = info.layout.columnLeft[border]
        resizing = (column, edge)
        needsDisplay = true
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { next, stop in
            guard let next else { stop.pointee = true; return }
            edge = max(minEdge, self.convert(next.locationInWindow, from: nil).x)
            self.resizing = (column, edge)
            self.needsDisplay = true
            if next.type == .leftMouseUp { stop.pointee = true }
        }
        resizing = nil
        needsDisplay = true
        let width = edge - left
        guard abs(width - info.layout.columnWidth(column)) >= 1 else { return }
        var table = tableWithFieldValue()
        table.setColumnWidth(column, to: width, availableWidth: info.availableWidth)
        commitAndMove(to: nil, table: table, actionName: "Resize Column")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = info.layout.cell(at: point) else { return nil }
        return contextMenu(for: cell)
    }

    // MARK: Editing

    func beginEditing(row: Int, column: Int) {
        let table = info.table
        let cell = (row: min(max(row, 0), table.rowCount - 1), column: min(max(column, 0), table.columnCount - 1))
        endFieldWithoutCommit()
        guard let textView else { return }

        let field = TableCellField(string: table[cell.row, cell.column])
        field.delegate = self
        let baseFont = textView.baseFont
        field.font = cell.row == 0
            ? (PlatformFont.md(descriptor: baseFont.fontDescriptor, traits: .bold, size: baseFont.pointSize) ?? baseFont)
            : baseFont
        field.textColor = textView.configuration.theme.bodyText
        field.alignment = MarkdownStyler.tableTextAlignment(table.alignments[cell.column])
        let background = textView.configuration.theme.background ?? NSColor.textBackgroundColor
        field.backgroundColor = cell.row == 0
            ? background.blended(withFraction: 0.08, of: textView.configuration.theme.mutedText) ?? background
            : background
        addSubview(field)
        self.field = field
        editingCell = cell
        positionField(for: cell)
        needsDisplay = true

        window?.makeFirstResponder(field)
        // Caret at the end, like clicking into a text cell in Numbers.
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        scrollToVisible(info.layout.cellRect(row: cell.row, column: cell.column))
    }

    private func positionField(for cell: (row: Int, column: Int)) {
        guard let field else { return }
        // NSTextField insets its text ~2pt; widen so field text lines up with the rendered text.
        let textWidth = (field.stringValue as NSString).size(withAttributes: [.font: field.font as Any]).width + 8
        field.frame = info.layout.editorFrame(
            row: cell.row, column: cell.column, textWidth: textWidth,
            alignment: info.table.alignments[cell.column]
        ).insetBy(dx: -2, dy: 0)
    }

    func controlTextDidChange(_ notification: Notification) {
        if let editingCell { positionField(for: editingCell) }
        needsDisplay = true
    }

    /// Removes the field without writing its value back.
    private func endFieldWithoutCommit() {
        guard let field else { return }
        isFinishingEdit = true
        field.abortEditing()
        field.removeFromSuperview()
        isFinishingEdit = false
        self.field = nil
        editingCell = nil
        needsDisplay = true
    }

    /// The table with the field's current value applied.
    private func tableWithFieldValue() -> MarkdownTable {
        var table = info.table
        if let field, let cell = editingCell {
            // A typed `=SUM(A1:A2)` becomes the formula link `[?](#SUM(A1:A2))`.
            table[cell.row, cell.column] = MarkdownFormulas.cellSource(fromTyped: field.stringValue)
        }
        return table
    }

    /// Writes the edited cell back (if it changed) and continues at `next`.
    private func commitAndMove(to next: (row: Int, column: Int)?, table override: MarkdownTable? = nil, actionName: String = "Edit Table") {
        let table = override ?? tableWithFieldValue()
        endFieldWithoutCommit()
        if table != info.table, let textView {
            textView.replaceTable(at: info.sourceRange, with: table, actionName: actionName, focus: next)
        } else if let next {
            beginEditing(row: next.row, column: next.column)
        }
    }

    private func leaveTable(below: Bool, commit: Bool) {
        let table = commit ? tableWithFieldValue() : info.table
        let range = info.sourceRange
        endFieldWithoutCommit()
        guard let textView else { return }
        var tableRange = range
        if table != info.table {
            textView.replaceTable(at: range, with: table, actionName: "Edit Table", focus: nil)
            // The replacement keeps the table's start; its end follows the new source.
            tableRange.length = (table.markdown() as NSString).length
        }
        textView.exitTable(range: tableRange, below: below)
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let cell = editingCell else { return false }
        let move: TableGridMove
        switch selector {
        case #selector(NSResponder.insertTab(_:)): move = .next
        case #selector(NSResponder.insertBacktab(_:)): move = .previous
        case #selector(NSResponder.insertNewline(_:)): move = .newline
        case #selector(NSResponder.moveUp(_:)): move = .up
        case #selector(NSResponder.moveDown(_:)): move = .down
        case #selector(NSResponder.cancelOperation(_:)):
            leaveTable(below: true, commit: false)
            return true
        default:
            return false
        }
        switch tableWithFieldValue().outcome(of: move, fromRow: cell.row, column: cell.column) {
        case .focus(let table, let row, let column, let actionName):
            commitAndMove(to: (row, column), table: table, actionName: actionName)
        case .exit(_, let below):
            leaveTable(below: below, commit: true)
        case .stay:
            break
        }
        return true
    }

    /// Focus left the field some other way (click elsewhere): keep the edit.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard !isFinishingEdit, field != nil else { return }
        commitAndMove(to: nil)
    }

    // MARK: Context menu

    private func contextMenu(for cell: (row: Int, column: Int)) -> NSMenu {
        menu(for: info.table.contextCommands(row: cell.row, column: cell.column))
    }

    private func menu(for groups: [[TableGridCommand]]) -> NSMenu {
        let menu = NSMenu()
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for command in group {
                let item = TableMenuItem(title: command.title, action: #selector(runCommand(_:)), keyEquivalent: "")
                item.image = MenuIcons.image(for: command.title)
                item.target = self
                item.isEnabled = command.isEnabled
                item.state = command.isChecked ? .on : .off
                item.command = command
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func runCommand(_ sender: TableMenuItem) {
        guard let command = sender.command else { return }
        switch command.action {
        case .edit(let edit):
            var table = tableWithFieldValue()
            let focus = edit(&table)
            commitAndMove(to: focus, table: table, actionName: command.title)
        case .revealSource:
            commitAndMove(to: nil)
            guard let textView else { return }
            textView.coordinator?.revealTableSource(at: info.sourceRange.location, in: textView)
        }
    }
}

/// Single-line, borderless cell editor.
final class TableCellField: NSTextField {
    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
        isBordered = false
        isBezeled = false
        drawsBackground = true
        focusRingType = .none
        lineBreakMode = .byClipping
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
    }
}

private final class TableMenuItem: NSMenuItem {
    var command: TableGridCommand?
}
#endif
