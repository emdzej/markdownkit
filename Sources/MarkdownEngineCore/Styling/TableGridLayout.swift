//
//  TableGridLayout.swift
//  MarkdownEngine
//
//  Geometry and drawing of a rendered GFM table. The styler draws the
//  table image from this layout, and the interactive table grid uses the
//  same layout to hit-test cells and position the cell editor, so what you
//  click is exactly what you see.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

struct TableGridLayout {
    static let cellHPadding: CGFloat = 12
    static let cellVPadding: CGFloat = 6
    static let borderWidth: CGFloat = 1
    static let minColumnContentWidth: CGFloat = 16

    /// Left edge of each column's box; `columnCount + 1` entries (last = right border).
    let columnLeft: [CGFloat]
    /// Top edge of each row's box; `rowCount + 1` entries (row 0 = header).
    let rowTop: [CGFloat]
    let rowHeight: CGFloat
    /// Height of one line of cell text (cells are single-line).
    let lineHeight: CGFloat
    let size: CGSize

    var columnCount: Int { columnLeft.count - 1 }
    var rowCount: Int { rowTop.count - 1 }

    /// Measures formatted cells (row 0 = header) and lays out the grid.
    init(cells: [[NSAttributedString]], columnCount: Int, baseFont: PlatformFont) {
        let b = Self.borderWidth, h = Self.cellHPadding, v = Self.cellVPadding
        let baseLineHeight = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
        var widths = [CGFloat](repeating: Self.minColumnContentWidth, count: columnCount)
        var maxCellHeight = baseLineHeight
        for row in cells {
            for (i, cell) in row.enumerated() where i < columnCount {
                let s = cell.size()
                widths[i] = max(widths[i], ceil(s.width))
                maxCellHeight = max(maxCellHeight, ceil(s.height))
            }
        }
        lineHeight = max(baseLineHeight, maxCellHeight)
        rowHeight = lineHeight + 2 * v

        var left = [b]
        for w in widths { left.append(left.last! + w + 2 * h + b) }
        columnLeft = left
        var top = [b]
        for _ in 0..<cells.count { top.append(top.last! + rowHeight + b) }
        rowTop = top
        size = CGSize(width: left.last!, height: top.last!)
    }

    /// The cell's box inside the borders.
    func cellRect(row: Int, column: Int) -> CGRect {
        CGRect(
            x: columnLeft[column], y: rowTop[row],
            width: columnLeft[column + 1] - Self.borderWidth - columnLeft[column],
            height: rowHeight
        )
    }

    /// The text area of a cell (box minus padding), one line tall.
    func contentRect(row: Int, column: Int) -> CGRect {
        let box = cellRect(row: row, column: column)
        return CGRect(
            x: box.minX + Self.cellHPadding,
            y: box.minY + max(0, (rowHeight - lineHeight) / 2),
            width: box.width - 2 * Self.cellHPadding,
            height: lineHeight
        )
    }

    /// Frame for the cell editor: the cell's text area, widened to fit
    /// `textWidth` (growing away from the alignment edge) but kept inside the table.
    func editorFrame(row: Int, column: Int, textWidth: CGFloat, alignment: MarkdownTable.Alignment) -> CGRect {
        var frame = contentRect(row: row, column: column)
        let extra = ceil(textWidth) - frame.width
        guard extra > 0 else { return frame }
        switch alignment {
        case .none, .left: frame.size.width += extra
        case .right: frame.origin.x -= extra; frame.size.width += extra
        case .center: frame.origin.x -= extra / 2; frame.size.width += extra
        }
        let inner = CGRect(origin: .zero, size: size).insetBy(dx: Self.borderWidth, dy: 0)
        if frame.width > inner.width { return CGRect(x: inner.minX, y: frame.minY, width: inner.width, height: frame.height) }
        if frame.minX < inner.minX { frame.origin.x = inner.minX }
        if frame.maxX > inner.maxX { frame.origin.x = inner.maxX - frame.width }
        return frame
    }

    /// Cell under `point` (top-left-origin table coordinates); borders count
    /// toward the cell to their right / below.
    func cell(at point: CGPoint) -> (row: Int, column: Int)? {
        guard point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else { return nil }
        let column = (columnLeft.lastIndex { $0 <= point.x } ?? 0)
        let row = (rowTop.lastIndex { $0 <= point.y } ?? 0)
        return (min(row, rowCount - 1), min(column, columnCount - 1))
    }
}

/// Everything the table grid needs about one rendered table, attached to the
/// table's anchor character as `.tableRenderInfo`.
final class TableRenderInfo: NSObject {
    let table: MarkdownTable
    /// Source range of the whole table in the document at styling time.
    let sourceRange: NSRange
    let layout: TableGridLayout
    let image: PlatformImage

    init(table: MarkdownTable, sourceRange: NSRange, layout: TableGridLayout, image: PlatformImage) {
        self.table = table
        self.sourceRange = sourceRange
        self.layout = layout
        self.image = image
    }
}

extension NSAttributedString.Key {
    /// `TableRenderInfo` on a rendered table's anchor character.
    static let tableRenderInfo = NSAttributedString.Key("TableRenderInfo")
}

extension MarkdownStyler {

    /// Draws `cells` (row 0 = header) into an image laid out by `layout`.
    static func renderTable(
        cells: [[NSAttributedString]],
        alignments: [MarkdownTable.Alignment],
        layout: TableGridLayout,
        theme: MarkdownEditorTheme,
        appearance: PlatformAppearance
    ) -> PlatformImage {
        let b = TableGridLayout.borderWidth
        let size = layout.size
        // Resolve under the real appearance: `.withAlphaComponent()` freezes a dynamic color otherwise.
        let muted = theme.mutedText.mdResolved(in: appearance)
        let borderColor = muted.withAlphaComponent(0.5)
        let headerFill = muted.withAlphaComponent(0.08)

        return PlatformImage.mdDrawing(size: size) {
            headerFill.setFill()
            PlatformBezierPath(rect: CGRect(x: b, y: b, width: size.width - 2 * b, height: layout.rowHeight)).fill()

            borderColor.setStroke()
            let outer = PlatformBezierPath(rect: CGRect(x: b / 2, y: b / 2, width: size.width - b, height: size.height - b))
            outer.lineWidth = b
            outer.stroke()

            let separators = PlatformBezierPath()
            separators.lineWidth = b
            for i in 1..<layout.columnCount {
                let x = layout.columnLeft[i] - b / 2
                separators.move(to: CGPoint(x: x, y: 0))
                separators.line(to: CGPoint(x: x, y: size.height))
            }
            for i in 1..<layout.rowCount {
                let y = layout.rowTop[i] - b / 2
                separators.move(to: CGPoint(x: 0, y: y))
                separators.line(to: CGPoint(x: size.width, y: y))
            }
            separators.stroke()

            for (row, rowCells) in cells.enumerated() {
                for (col, cell) in rowCells.enumerated() where col < layout.columnCount {
                    let aligned = NSMutableAttributedString(attributedString: cell)
                    aligned.addAttribute(
                        .paragraphStyle,
                        value: tableCellParagraphStyle(alignments[col]),
                        range: NSRange(location: 0, length: aligned.length)
                    )
                    aligned.draw(
                        with: layout.contentRect(row: row, column: col),
                        options: [.usesLineFragmentOrigin], context: nil
                    )
                }
            }
        }
    }

    static func tableCellParagraphStyle(_ alignment: MarkdownTable.Alignment) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = tableTextAlignment(alignment)
        paragraph.lineBreakMode = .byClipping
        return paragraph
    }

    static func tableTextAlignment(_ alignment: MarkdownTable.Alignment) -> NSTextAlignment {
        switch alignment {
        case .none, .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}
