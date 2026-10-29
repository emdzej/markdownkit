//
//  TableGridMarkers.swift
//  MarkdownEngine
//
//  The editing markers of a rendered table: a handle above each column and
//  left of each row (opens that column's / row's menu), "+" buttons on the
//  borders between columns and rows (insert there), and add-row /
//  add-column bars below and right of the table. They live in the gutters
//  `TableGridLayout` reserves, appear with the pointer (macOS) or while a
//  cell is edited (iOS), and are drawn and hit-tested from the layout so
//  both platforms agree.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

enum TableGridMarker: Equatable, Hashable {
    /// Above column `n`: its menu.
    case columnHandle(Int)
    /// Left of row `n` (0 = header): its menu.
    case rowHandle(Int)
    /// On the border before column `n` (0…columnCount): inserts a column there.
    case insertColumn(Int)
    /// On the border above body row `n` (1…rowCount; rowCount = after the last): inserts a row there.
    case insertRow(Int)
    /// Below the table: appends a row.
    case addRow
    /// Right of the table: appends a column.
    case addColumn
}

extension TableGridLayout {
    static let handleLength: CGFloat = 22
    static let handleThickness: CGFloat = 6
    static let plusDiameter: CGFloat = 15

    /// Where `marker` is drawn.
    func rect(for marker: TableGridMarker) -> CGRect {
        let t = tableRect, b = Self.borderWidth
        let gutterMid = t.minY - Self.gutter.top / 2
        switch marker {
        case .columnHandle(let c):
            let mid = (columnLeft[c] + columnLeft[c + 1] - b) / 2
            return CGRect(x: mid - Self.handleLength / 2, y: gutterMid - Self.handleThickness / 2,
                          width: Self.handleLength, height: Self.handleThickness)
        case .rowHandle(let r):
            let length = min(Self.handleLength, rowHeight(r) - 6)
            let mid = rowTop[r] + rowHeight(r) / 2
            return CGRect(x: t.minX + 3, y: mid - length / 2, width: Self.handleThickness, height: length)
        case .insertColumn(let i):
            let d = Self.plusDiameter
            let x = min(max(columnLeft[i] - b / 2, d / 2), size.width - d / 2)
            return CGRect(x: x - d / 2, y: gutterMid - d / 2, width: d, height: d)
        case .insertRow(let i):
            let d = Self.plusDiameter
            return CGRect(x: t.minX + 1, y: rowTop[i] - b / 2 - d / 2, width: d, height: d)
        case .addRow:
            return CGRect(x: t.minX, y: t.maxY + 4, width: t.width, height: Self.gutter.bottom - 8)
        case .addColumn:
            return CGRect(x: t.maxX + 4, y: t.minY, width: Self.gutter.right - 8, height: t.height)
        }
    }

    /// The markers to show with the pointer at `pointer` and/or a cell being
    /// edited. Insert buttons only appear near their border.
    func visibleMarkers(pointer: CGPoint?, editing: (row: Int, column: Int)?) -> [TableGridMarker] {
        var markers: [TableGridMarker] = []
        if let editing {
            markers += [.columnHandle(editing.column), .rowHandle(editing.row)]
        }
        if let p = pointer, CGRect(origin: .zero, size: size).contains(p) {
            let t = tableRect
            if p.x >= t.minX, p.x < t.maxX, let c = columnLeft.lastIndex(where: { $0 <= p.x }) {
                markers.append(.columnHandle(min(c, columnCount - 1)))
            }
            if p.y >= t.minY, p.y < t.maxY, let r = rowTop.lastIndex(where: { $0 <= p.y }) {
                markers.append(.rowHandle(min(r, rowCount - 1)))
            }
            // Near a column border, in the top gutter or the header row.
            if p.y < rowTop[1] {
                for i in 0...columnCount where abs(columnLeft[i] - Self.borderWidth / 2 - p.x) < 12 {
                    markers.append(.insertColumn(i))
                }
            }
            // Near a row border below the header, at the table's left edge.
            if p.x < t.minX + 28 {
                for i in 1...rowCount where abs(rowTop[i] - Self.borderWidth / 2 - p.y) < 8 {
                    markers.append(.insertRow(i))
                }
            }
        }
        if pointer != nil || editing != nil { markers += [.addRow, .addColumn] }
        var seen = Set<TableGridMarker>()
        return markers.filter { seen.insert($0).inserted }
    }

    /// The marker at `point` among `visible`; "+" buttons win over handles.
    func marker(at point: CGPoint, among visible: [TableGridMarker]) -> TableGridMarker? {
        let ordered = visible.sorted { Self.priority($0) < Self.priority($1) }
        return ordered.first { rect(for: $0).insetBy(dx: -5, dy: -5).contains(point) }
    }

    private static func priority(_ marker: TableGridMarker) -> Int {
        switch marker {
        case .insertColumn, .insertRow: return 0
        case .columnHandle, .rowHandle: return 1
        case .addRow, .addColumn: return 2
        }
    }

    /// Draws `markers`; `highlighted` (under the pointer) in the accent color.
    func drawMarkers(_ markers: [TableGridMarker], highlighted: TableGridMarker?, accent: PlatformColor, muted: PlatformColor) {
        for marker in markers {
            let r = rect(for: marker)
            let hot = marker == highlighted
            switch marker {
            case .columnHandle, .rowHandle:
                (hot ? accent : muted.withAlphaComponent(0.45)).setFill()
                PlatformBezierPath(roundedRect: r, xRadius: r.width.mdMin(r.height) / 2, yRadius: r.width.mdMin(r.height) / 2).fill()
            case .insertColumn, .insertRow:
                (hot ? accent : accent.withAlphaComponent(0.85)).setFill()
                PlatformBezierPath(ovalIn: r).fill()
                Self.drawPlus(in: r.insetBy(dx: 4, dy: 4), color: .white, lineWidth: 1.6)
            case .addRow, .addColumn:
                (hot ? accent.withAlphaComponent(0.16) : muted.withAlphaComponent(0.08)).setFill()
                PlatformBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                let side = min(r.width, r.height) - 4
                let glyph = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
                Self.drawPlus(in: glyph, color: hot ? accent : muted.withAlphaComponent(0.7), lineWidth: 1.4)
            }
        }
    }

    private static func drawPlus(in r: CGRect, color: PlatformColor, lineWidth: CGFloat) {
        color.setStroke()
        let plus = PlatformBezierPath()
        plus.lineWidth = lineWidth
        plus.move(to: CGPoint(x: r.midX, y: r.minY))
        plus.line(to: CGPoint(x: r.midX, y: r.maxY))
        plus.move(to: CGPoint(x: r.minX, y: r.midY))
        plus.line(to: CGPoint(x: r.maxX, y: r.midY))
        plus.stroke()
    }

    /// The table after the "+" marker's insert, and the cell to edit next; nil for handles.
    func apply(_ marker: TableGridMarker, to table: MarkdownTable) -> (table: MarkdownTable, focus: (row: Int, column: Int), actionName: String)? {
        var t = table
        switch marker {
        case .insertColumn(let i): t.insertColumn(at: i); return (t, (0, i), "Insert Column")
        case .addColumn: t.insertColumn(at: t.columnCount); return (t, (0, t.columnCount - 1), "Add Column")
        case .insertRow(let i): t.insertRow(at: i); return (t, (i, 0), "Insert Row")
        case .addRow: t.insertRow(at: t.rowCount); return (t, (t.rowCount - 1, 0), "Add Row")
        case .columnHandle, .rowHandle: return nil
        }
    }
}

private extension CGFloat {
    func mdMin(_ other: CGFloat) -> CGFloat { Swift.min(self, other) }
}
