#if os(iOS) || os(visionOS)
//
//  TableGridUIView.swift
//  MarkdownEngine
//
//  UIKit counterpart of `TableGridView`: draws a rendered table and edits
//  one cell at a time in an inline text field showing the cell's raw inline
//  markdown. Tap a cell to edit it; long-press for row / column / alignment
//  commands. Hardware-keyboard Tab, Shift-Tab, arrows, and Esc behave as on
//  macOS (see `TableGridNavigation`); the software keyboard's Return key
//  moves down a row.
//

import UIKit

/// Horizontal scroller hosting a table grid; one per rendered table.
final class TableOverlayUIView: UIScrollView {
    var sourceID: Int
    let gridView: TableGridUIView
    var tableLocation: Int { gridView.info.sourceRange.location }

    init(sourceID: Int, info: TableRenderInfo, textView: MarkdownUITextView) {
        self.sourceID = sourceID
        gridView = TableGridUIView(info: info, textView: textView)
        super.init(frame: .zero)
        addSubview(gridView)
        contentSize = info.layout.size
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        // Let vertical drags fall through to the document scroll.
        isDirectionalLockEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(info: TableRenderInfo) {
        guard gridView.info !== info else { return }
        gridView.update(info: info)
        contentSize = info.layout.size
    }
}

final class TableGridUIView: UIView, UITextFieldDelegate, UIContextMenuInteractionDelegate {

    private(set) var info: TableRenderInfo
    weak var textView: MarkdownUITextView?

    private var field: TableCellTextField?
    private(set) var editingCell: (row: Int, column: Int)?
    private var isFinishingEdit = false

    init(info: TableRenderInfo, textView: MarkdownUITextView) {
        self.info = info
        self.textView = textView
        super.init(frame: CGRect(origin: .zero, size: info.layout.size))
        backgroundColor = .clear
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(info: TableRenderInfo) {
        self.info = info
        frame.size = info.layout.size
        if let editingCell, editingCell.row < info.table.rowCount, editingCell.column < info.table.columnCount {
            positionField(for: editingCell)
        }
        setNeedsDisplay()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        info.image.draw(in: bounds)
        guard let cell = editingCell, let textView else { return }
        // Blank the rendered text under the field, keeping the header tint;
        // a field grown past its cell gets the ring around its full width.
        var content = info.layout.cellRect(row: cell.row, column: cell.column)
        if let field { content = content.union(CGRect(x: field.frame.minX, y: content.minY, width: field.frame.width, height: content.height)) }
        UIColor.systemBackground.setFill()
        UIRectFill(content)
        if cell.row == 0 {
            textView.configuration.theme.mutedText.withAlphaComponent(0.08).setFill()
            UIRectFillUsingBlendMode(content, .normal)
        }
        tintColor.setStroke()
        let ring = UIBezierPath(rect: content.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        ring.stroke()
    }

    // MARK: Editing

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let cell = info.layout.cell(at: gesture.location(in: self)) else { return }
        if let editingCell, editingCell == cell { return }
        commitAndMove(to: cell)
    }

    func beginEditing(row: Int, column: Int) {
        let table = info.table
        let cell = (row: min(max(row, 0), table.rowCount - 1), column: min(max(column, 0), table.columnCount - 1))
        endFieldWithoutCommit()
        guard let textView else { return }

        let field = TableCellTextField()
        field.text = table[cell.row, cell.column]
        field.delegate = self
        field.grid = self
        let baseFont = textView.baseFont
        field.font = cell.row == 0
            ? (PlatformFont.md(descriptor: baseFont.fontDescriptor, traits: .bold, size: baseFont.pointSize) ?? baseFont)
            : baseFont
        field.textColor = textView.configuration.theme.bodyText
        field.textAlignment = MarkdownStyler.tableTextAlignment(table.alignments[cell.column])
        field.borderStyle = .none
        // Opaque: a grown field covers neighbouring cells.
        field.backgroundColor = cell.row == 0 ? Self.headerBackground(textView.configuration.theme) : .systemBackground
        field.addTarget(self, action: #selector(fieldTextChanged), for: .editingChanged)
        field.returnKeyType = .next
        field.autocorrectionType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        addSubview(field)
        self.field = field
        editingCell = cell
        positionField(for: cell)
        setNeedsDisplay()
        field.becomeFirstResponder()
        (superview as? UIScrollView)?.scrollRectToVisible(info.layout.cellRect(row: cell.row, column: cell.column), animated: true)
    }

    private func positionField(for cell: (row: Int, column: Int)) {
        guard let field else { return }
        let textWidth = (field.text as NSString? ?? "").size(withAttributes: [.font: field.font as Any]).width + 4
        field.frame = info.layout.editorFrame(
            row: cell.row, column: cell.column, textWidth: textWidth,
            alignment: info.table.alignments[cell.column]
        )
    }

    @objc private func fieldTextChanged() {
        if let editingCell { positionField(for: editingCell) }
        setNeedsDisplay()
    }

    /// The header fill (muted at 8%) composited over the page background.
    private static func headerBackground(_ theme: MarkdownEditorTheme) -> UIColor {
        UIColor { traits in
            let base = UIColor.systemBackground.resolvedColor(with: traits)
            let tint = theme.mutedText.resolvedColor(with: traits)
            var (r1, g1, b1, a1, r2, g2, b2, a2) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            base.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            tint.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            let t: CGFloat = 0.08
            return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
        }
    }

    private func endFieldWithoutCommit() {
        guard let field else { return }
        isFinishingEdit = true
        field.resignFirstResponder()
        field.removeFromSuperview()
        isFinishingEdit = false
        self.field = nil
        editingCell = nil
        setNeedsDisplay()
    }

    private func tableWithFieldValue() -> MarkdownTable {
        var table = info.table
        if let field, let cell = editingCell { table[cell.row, cell.column] = field.text ?? "" }
        return table
    }

    private func commitAndMove(to next: (row: Int, column: Int)?, table override: MarkdownTable? = nil, actionName: String = "Edit Table") {
        let table = override ?? tableWithFieldValue()
        // Keep the keyboard up while hopping between cells (the next field
        // may only appear after the table re-renders).
        if next != nil {
            // The field resigns to the keeper; that is not a user "done editing".
            isFinishingEdit = true
            textView?.holdKeyboard()
            isFinishingEdit = false
        }
        endFieldWithoutCommit()
        if table != info.table, let textView {
            textView.replaceTable(at: info.sourceRange, with: table, actionName: actionName, focus: next)
        } else if let next {
            beginEditing(row: next.row, column: next.column)
        }
    }

    private func leaveTable(below: Bool, commit: Bool) {
        let table = commit ? tableWithFieldValue() : info.table
        var range = info.sourceRange
        endFieldWithoutCommit()
        guard let textView else { return }
        if table != info.table {
            textView.replaceTable(at: range, with: table, actionName: "Edit Table", focus: nil)
            range.length = (table.markdown() as NSString).length
        }
        textView.exitTable(range: range, below: below)
    }

    /// Hardware-keyboard and Return-key moves.
    fileprivate func perform(_ move: TableGridMove) {
        guard let cell = editingCell else { return }
        switch tableWithFieldValue().outcome(of: move, fromRow: cell.row, column: cell.column) {
        case .focus(let table, let row, let column, let actionName):
            commitAndMove(to: (row, column), table: table, actionName: actionName)
        case .exit(_, let below):
            leaveTable(below: below, commit: true)
        case .stay:
            break
        }
    }

    fileprivate func cancelEditing() {
        leaveTable(below: true, commit: false)
    }

    // MARK: UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        perform(.newline)
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard !isFinishingEdit, field === textField else { return }
        commitAndMove(to: nil)
    }

    // MARK: Context menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let cell = info.layout.cell(at: location) else { return nil }
        let groups = info.table.contextCommands(row: cell.row, column: cell.column)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: groups.map { group in
                UIMenu(options: .displayInline, children: group.map { command in
                    UIAction(
                        title: command.title,
                        attributes: command.isEnabled ? [] : .disabled,
                        state: command.isChecked ? .on : .off
                    ) { _ in self?.run(command) }
                })
            })
        }
    }

    private func run(_ command: TableGridCommand) {
        switch command.action {
        case .edit(let edit):
            var table = tableWithFieldValue()
            let focus = edit(&table)
            commitAndMove(to: focus, table: table, actionName: command.title)
        case .revealSource:
            commitAndMove(to: nil)
            guard let textView else { return }
            (textView.delegate as? MarkdownUICoordinator)?.revealTableSource(at: info.sourceRange.location, in: textView)
        }
    }
}

/// Single-line cell editor with hardware-keyboard grid navigation.
final class TableCellTextField: UITextField {
    weak var grid: TableGridUIView?

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(nextCell)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(previousCell)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(cellAbove)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(cellBelow)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func nextCell() { grid?.perform(.next) }
    @objc private func previousCell() { grid?.perform(.previous) }
    @objc private func cellAbove() { grid?.perform(.up) }
    @objc private func cellBelow() { grid?.perform(.down) }
    @objc private func cancel() { grid?.cancelEditing() }
}
#endif
