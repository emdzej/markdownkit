//
//  TableGridNavigation.swift
//  MarkdownEngine
//
//  Platform-neutral keyboard behavior of the table grid: given the table
//  (with the edited cell's value applied), the current cell, and a key,
//  decide where focus goes and whether the table grows. Shared by the
//  AppKit and UIKit grid views.
//

import Foundation

/// A cell to focus in the table that starts at `tableLocation`, once that
/// table's grid is (re-)rendered.
struct TableCellFocus: Equatable {
    var tableLocation: Int
    var row: Int
    var column: Int
}

enum TableGridMove {
    /// Tab: next cell, wrapping to the next row; past the last cell adds a row.
    case next
    /// Shift-Tab: previous cell, wrapping to the previous row.
    case previous
    /// Return: cell below; from the last row adds a row.
    case newline
    /// Up arrow: cell above; leaves the table above row 0.
    case up
    /// Down arrow: cell below; leaves the table below the last row.
    case down
}

enum TableGridOutcome: Equatable {
    /// Keep editing at `cell` in `table` (which may have grown).
    case focus(table: MarkdownTable, row: Int, column: Int, actionName: String)
    /// Leave the grid, writing `table` back first; caret goes above / below.
    case exit(table: MarkdownTable, below: Bool)
    /// Nothing to do (e.g. Shift-Tab in the first cell).
    case stay
}

extension MarkdownTable {
    func outcome(of move: TableGridMove, fromRow row: Int, column: Int) -> TableGridOutcome {
        let lastRow = rowCount - 1, lastColumn = columnCount - 1
        func grown() -> MarkdownTable {
            var t = self
            t.insertRow(at: t.rowCount)
            return t
        }
        switch move {
        case .next:
            if column < lastColumn { return .focus(table: self, row: row, column: column + 1, actionName: "Edit Table") }
            if row < lastRow { return .focus(table: self, row: row + 1, column: 0, actionName: "Edit Table") }
            return .focus(table: grown(), row: row + 1, column: 0, actionName: "Add Row")
        case .previous:
            if column > 0 { return .focus(table: self, row: row, column: column - 1, actionName: "Edit Table") }
            if row > 0 { return .focus(table: self, row: row - 1, column: lastColumn, actionName: "Edit Table") }
            return .stay
        case .newline:
            if row < lastRow { return .focus(table: self, row: row + 1, column: column, actionName: "Edit Table") }
            return .focus(table: grown(), row: row + 1, column: column, actionName: "Add Row")
        case .up:
            if row > 0 { return .focus(table: self, row: row - 1, column: column, actionName: "Edit Table") }
            return .exit(table: self, below: false)
        case .down:
            if row < lastRow { return .focus(table: self, row: row + 1, column: column, actionName: "Edit Table") }
            return .exit(table: self, below: true)
        }
    }
}

// MARK: - Context menu

/// One context-menu entry of the table grid.
struct TableGridCommand {
    enum Action {
        /// Applies a structural edit; returns the cell to keep editing, if any.
        case edit((inout MarkdownTable) -> (row: Int, column: Int)?)
        /// Show this table as raw markdown.
        case revealSource
    }

    let title: String
    var isEnabled = true
    var isChecked = false
    let action: Action
}

extension MarkdownTable {
    /// Context-menu commands for the cell at (`row`, `column`), in groups.
    func contextCommands(row r: Int, column c: Int) -> [[TableGridCommand]] {
        let alignment = alignments[c]
        func align(_ title: String, _ value: Alignment) -> TableGridCommand {
            let current = alignment == .none ? .left : alignment
            return TableGridCommand(title: title, isChecked: current == value,
                                    action: .edit { $0.alignments[c] = value; return nil })
        }
        return [
            [
                TableGridCommand(title: "Insert Row Above", isEnabled: r > 0,
                                 action: .edit { $0.insertRow(at: r); return (r, c) }),
                TableGridCommand(title: "Insert Row Below",
                                 action: .edit { $0.insertRow(at: r + 1); return (r + 1, c) }),
                TableGridCommand(title: "Delete Row", isEnabled: r > 0,
                                 action: .edit { $0.removeRow(r); return nil }),
            ],
            [
                TableGridCommand(title: "Insert Column Left",
                                 action: .edit { $0.insertColumn(at: c); return (r, c) }),
                TableGridCommand(title: "Insert Column Right",
                                 action: .edit { $0.insertColumn(at: c + 1); return (r, c + 1) }),
                TableGridCommand(title: "Delete Column", isEnabled: columnCount > 1,
                                 action: .edit { $0.removeColumn(c); return nil }),
            ],
            [
                TableGridCommand(title: "Move Column Left", isEnabled: c > 0,
                                 action: .edit { $0.moveColumn(c, to: c - 1); return nil }),
                TableGridCommand(title: "Move Column Right", isEnabled: c < columnCount - 1,
                                 action: .edit { $0.moveColumn(c, to: c + 1); return nil }),
            ],
            [align("Align Left", .left), align("Align Center", .center), align("Align Right", .right)],
            [TableGridCommand(title: "Edit as Markdown", action: .revealSource)],
        ]
    }
}
