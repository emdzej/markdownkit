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
//  While a cell is edited, the markers of `TableGridMarkers` show: the
//  handles of its column and row open their menus, the bars below / right
//  add a row / column, and dragging a column border near the edited
//  column sets its width (`{cols="…"}` after the table).
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

final class TableGridUIView: UIView, UITextFieldDelegate, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {

    private(set) var info: TableRenderInfo
    weak var textView: MarkdownUITextView?

    private var field: TableCellTextField?
    private(set) var editingCell: (row: Int, column: Int)?
    private var isFinishingEdit = false
    /// Menu buttons over the edited cell's column and row handles.
    private var handleButtons: [UIButton] = []
    /// A column border being dragged: the column left of it and the new right edge.
    private var resizing: (column: Int, edge: CGFloat)?

    init(info: TableRenderInfo, textView: MarkdownUITextView) {
        self.info = info
        self.textView = textView
        super.init(frame: CGRect(origin: .zero, size: info.layout.size))
        backgroundColor = .clear
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(info: TableRenderInfo) {
        self.info = info
        frame.size = info.layout.size
        if let editingCell, editingCell.row < info.table.rowCount, editingCell.column < info.table.columnCount {
            positionField(for: editingCell)
        }
        updateHandleButtons()
        setNeedsDisplay()
    }

    // MARK: Markers

    private var visibleMarkers: [TableGridMarker] {
        guard resizing == nil, let editingCell else { return [] }
        return info.layout.visibleMarkers(pointer: nil, editing: editingCell)
    }

    /// Invisible menu buttons (enlarged for touch) over the edited cell's handles.
    private func updateHandleButtons() {
        handleButtons.forEach { $0.removeFromSuperview() }
        handleButtons = []
        guard let cell = editingCell, cell.row < info.table.rowCount, cell.column < info.table.columnCount else { return }
        let items: [(TableGridMarker, [[TableGridCommand]], String)] = [
            (.columnHandle(cell.column), info.table.columnCommands(cell.column), "Column"),
            (.rowHandle(cell.row), info.table.rowCommands(cell.row), "Row"),
        ]
        for (marker, groups, label) in items {
            let button = UIButton(type: .custom)
            button.frame = info.layout.rect(for: marker).insetBy(dx: -12, dy: -12)
            button.menu = menu(for: groups)
            button.showsMenuAsPrimaryAction = true
            button.accessibilityLabel = "\(label) Options"
            addSubview(button)
            handleButtons.append(button)
        }
    }

    private func menu(for groups: [[TableGridCommand]]) -> UIMenu {
        UIMenu(children: groups.map { group in
            UIMenu(options: .displayInline, children: group.map { command in
                UIAction(
                    title: command.title,
                    image: MenuIcons.image(for: command.title),
                    attributes: command.isEnabled ? [] : .disabled,
                    state: command.isChecked ? .on : .off
                ) { [weak self] _ in self?.run(command) }
            })
        })
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture is UIPanGestureRecognizer else { return true }
        // Only a mostly-horizontal drag that starts on a column border, while editing.
        guard editingCell != nil, textView?.isEditable ?? false,
              info.layout.columnBorder(near: gesture.location(in: self), tolerance: 10) != nil,
              let pan = gesture as? UIPanGestureRecognizer else { return false }
        let v = pan.velocity(in: self)
        return abs(v.x) > abs(v.y)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let layout = info.layout
        switch pan.state {
        case .began:
            guard let border = layout.columnBorder(near: pan.location(in: self), tolerance: 10) else { return }
            resizing = (border - 1, layout.columnLeft[border])
        case .changed:
            guard let r = resizing else { return }
            let minEdge = layout.columnLeft[r.column] + TableGridLayout.minColumnWidth
            resizing = (r.column, max(minEdge, pan.location(in: self).x))
        case .ended:
            guard let r = resizing else { return }
            resizing = nil
            let width = r.edge - layout.columnLeft[r.column]
            if abs(width - layout.columnWidth(r.column)) >= 1 {
                var table = tableWithFieldValue()
                table.setColumnWidth(r.column, to: width, availableWidth: info.availableWidth)
                commitAndMove(to: editingCell, table: table, actionName: "Resize Column")
            }
        default:
            resizing = nil
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
        (textView.configuration.theme.background ?? .systemBackground).setFill()
        UIRectFill(content)
        if cell.row == 0 {
            textView.configuration.theme.tableHeaderFill.setFill()
            UIRectFillUsingBlendMode(content, .normal)
        }
        tintColor.setStroke()
        let ring = UIBezierPath(rect: content.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        ring.stroke()
        let accent = textView.configuration.theme.link
        if let resizing {
            accent.setFill()
            UIRectFill(CGRect(x: resizing.edge - 1, y: info.layout.tableRect.minY, width: 2, height: info.layout.tableRect.height))
        } else {
            info.layout.drawMarkers(visibleMarkers, highlighted: nil, accent: accent, muted: textView.configuration.theme.mutedText)
        }
    }

    // MARK: Editing

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if let marker = info.layout.marker(at: point, among: visibleMarkers),
           let result = info.layout.apply(marker, to: tableWithFieldValue()) {
            commitAndMove(to: result.focus, table: result.table, actionName: result.actionName)
            return
        }
        guard let cell = info.layout.cell(at: point) else { return }
        if let editingCell, editingCell == cell { return }
        commitAndMove(to: cell)
    }

    func beginEditing(row: Int, column: Int) {
        let table = info.table
        let cell = (row: min(max(row, 0), table.rowCount - 1), column: min(max(column, 0), table.columnCount - 1))
        endFieldWithoutCommit()
        guard let textView else { return }

        let field = TableCellTextField()
        field.text = Self.editableText(table[cell.row, cell.column])
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
        field.backgroundColor = cell.row == 0 ? Self.headerBackground(textView.configuration.theme) : (textView.configuration.theme.background ?? .systemBackground)
        field.addTarget(self, action: #selector(fieldTextChanged), for: .editingChanged)
        field.returnKeyType = .next
        field.autocorrectionType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        addSubview(field)
        self.field = field
        editingCell = cell
        positionField(for: cell)
        updateHandleButtons()
        setNeedsDisplay()
        field.becomeFirstResponder()
        (superview as? UIScrollView)?.scrollRectToVisible(info.layout.cellRect(row: cell.row, column: cell.column), animated: true)
        textView.editorController?.tableCellDidBeginEditing(field, row: cell.row, column: cell.column)
    }

    /// A formula cell is edited as `=SUM(A1:A2)`; it's stored back as
    /// `[?](#SUM(A1:A2))` on commit. Cells with more than the formula link stay raw.
    static func editableText(_ source: String) -> String {
        guard let formula = MarkdownFormulas.formula(inCell: source),
              MarkdownFormulas.cellSource(fromTyped: "=" + formula) == source.trimmingCharacters(in: .whitespaces)
        else { return source }
        return "=" + formula
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

    /// The header fill composited over the page background (the field is opaque).
    private static func headerBackground(_ theme: MarkdownEditorTheme) -> UIColor {
        UIColor { traits in
            let base = (theme.background ?? .systemBackground).resolvedColor(with: traits)
            let tint = theme.tableHeaderFill.resolvedColor(with: traits)
            var (r1, g1, b1, a1, r2, g2, b2, a2) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            base.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            tint.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            let t = a2
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
        updateHandleButtons()
        setNeedsDisplay()
    }

    private func tableWithFieldValue() -> MarkdownTable {
        var table = info.table
        // A typed `=SUM(A1:A2)` becomes the formula link `[?](#SUM(A1:A2))`.
        if let field, let cell = editingCell { table[cell.row, cell.column] = MarkdownFormulas.cellSource(fromTyped: field.text ?? "") }
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
        textView?.editorController?.tableCellDidEndEditing(textField)
        guard !isFinishingEdit, field === textField else { return }
        commitAndMove(to: nil)
    }

    // MARK: Context menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let cell = info.layout.cell(at: location) else { return nil }
        let groups = info.table.contextCommands(row: cell.row, column: cell.column)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: groups)
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
