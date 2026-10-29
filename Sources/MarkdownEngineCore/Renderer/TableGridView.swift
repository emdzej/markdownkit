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
//  Keys while editing a cell:
//    Tab / Shift-Tab   next / previous cell (Tab past the last cell adds a row)
//    Return            cell below (adds a row from the last row)
//    Up / Down         cell above / below; leaves the table at its edges
//    Esc               discard the cell's changes and leave the table
//

import AppKit

final class TableGridView: NSView, NSTextFieldDelegate {

    private(set) var info: TableRenderInfo
    weak var textView: NativeTextView?

    private var field: TableCellField?
    private(set) var editingCell: (row: Int, column: Int)?
    /// Set while focus moves programmatically, so end-of-editing doesn't commit twice.
    private var isFinishingEdit = false

    init(info: TableRenderInfo, textView: NativeTextView) {
        self.info = info
        self.textView = textView
        super.init(frame: CGRect(origin: .zero, size: info.layout.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func update(info: TableRenderInfo) {
        self.info = info
        setFrameSize(info.layout.size)
        if let editingCell, editingCell.row < info.table.rowCount, editingCell.column < info.table.columnCount {
            positionField(for: editingCell)
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        info.image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let cell = editingCell {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(rect: info.layout.cellRect(row: cell.row, column: cell.column).insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = info.layout.cell(at: point) else { return }
        if let editingCell, editingCell == cell { return }
        commitAndMove(to: cell)
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
        let background = NSColor.textBackgroundColor
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
        // NSTextField insets its text ~2pt; widen so field text lines up with the rendered text.
        field?.frame = info.layout.contentRect(row: cell.row, column: cell.column).insetBy(dx: -2, dy: 0)
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
            table[cell.row, cell.column] = field.stringValue
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
        let table = info.table
        let lastRow = table.rowCount - 1, lastColumn = table.columnCount - 1
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            if cell.column < lastColumn {
                commitAndMove(to: (cell.row, cell.column + 1))
            } else if cell.row < lastRow {
                commitAndMove(to: (cell.row + 1, 0))
            } else {
                var grown = tableWithFieldValue()
                grown.insertRow(at: grown.rowCount)
                commitAndMove(to: (cell.row + 1, 0), table: grown, actionName: "Add Row")
            }
        case #selector(NSResponder.insertBacktab(_:)):
            if cell.column > 0 {
                commitAndMove(to: (cell.row, cell.column - 1))
            } else if cell.row > 0 {
                commitAndMove(to: (cell.row - 1, lastColumn))
            }
        case #selector(NSResponder.insertNewline(_:)):
            if cell.row < lastRow {
                commitAndMove(to: (cell.row + 1, cell.column))
            } else {
                var grown = tableWithFieldValue()
                grown.insertRow(at: grown.rowCount)
                commitAndMove(to: (cell.row + 1, cell.column), table: grown, actionName: "Add Row")
            }
        case #selector(NSResponder.moveUp(_:)):
            if cell.row > 0 { commitAndMove(to: (cell.row - 1, cell.column)) } else { leaveTable(below: false, commit: true) }
        case #selector(NSResponder.moveDown(_:)):
            if cell.row < lastRow { commitAndMove(to: (cell.row + 1, cell.column)) } else { leaveTable(below: true, commit: true) }
        case #selector(NSResponder.cancelOperation(_:)):
            leaveTable(below: true, commit: false)
        default:
            return false
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
        let menu = NSMenu()
        func item(_ title: String, enabled: Bool = true, _ edit: @escaping (inout MarkdownTable) -> (row: Int, column: Int)?) {
            let menuItem = TableMenuItem(title: title, action: #selector(runMenuEdit(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.isEnabled = enabled
            menuItem.edit = edit
            menu.addItem(menuItem)
        }
        let r = cell.row, c = cell.column
        let table = info.table
        item("Insert Row Above", enabled: r > 0) { $0.insertRow(at: r); return (r, c) }
        item("Insert Row Below") { $0.insertRow(at: r + 1); return (r + 1, c) }
        item("Delete Row", enabled: r > 0) { $0.removeRow(r); return nil }
        menu.addItem(.separator())
        item("Insert Column Left") { $0.insertColumn(at: c); return (r, c) }
        item("Insert Column Right") { $0.insertColumn(at: c + 1); return (r, c + 1) }
        item("Delete Column", enabled: table.columnCount > 1) { $0.removeColumn(c); return nil }
        menu.addItem(.separator())
        item("Move Column Left", enabled: c > 0) { $0.moveColumn(c, to: c - 1); return nil }
        item("Move Column Right", enabled: c < table.columnCount - 1) { $0.moveColumn(c, to: c + 1); return nil }
        menu.addItem(.separator())
        for (title, alignment) in [("Align Left", MarkdownTable.Alignment.left), ("Align Center", .center), ("Align Right", .right)] {
            item(title) { $0.alignments[c] = alignment; return nil }
            if table.alignments[c] == alignment || (alignment == .left && table.alignments[c] == .none) {
                menu.items.last?.state = .on
            }
        }
        menu.addItem(.separator())
        let source = NSMenuItem(title: "Edit as Markdown", action: #selector(editAsMarkdown), keyEquivalent: "")
        source.target = self
        menu.addItem(source)
        return menu
    }

    @objc private func runMenuEdit(_ sender: TableMenuItem) {
        guard let edit = sender.edit else { return }
        var table = tableWithFieldValue()
        let focus = edit(&table)
        commitAndMove(to: focus, table: table, actionName: sender.title)
    }

    @objc private func editAsMarkdown() {
        commitAndMove(to: nil)
        guard let textView else { return }
        textView.coordinator?.revealTableSource(at: info.sourceRange.location, in: textView)
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
    var edit: ((inout MarkdownTable) -> (row: Int, column: Int)?)?
}
#endif
