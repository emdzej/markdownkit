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
    /// Narrowest column box a drag or a width attribute can make.
    static let minColumnWidth: CGFloat = minColumnContentWidth + 2 * cellHPadding + borderWidth
    /// Room around the table for the editing markers: column handles and
    /// insert buttons above, the add-column button right, add-row below.
    static let gutter = (top: CGFloat(14), right: CGFloat(22), bottom: CGFloat(20))

    /// Left edge of each column's box; `columnCount + 1` entries (last = right border).
    let columnLeft: [CGFloat]
    /// Top edge of each row's box; `rowCount + 1` entries (row 0 = header).
    let rowTop: [CGFloat]
    /// Height of one line of cell text; rows are at least one line tall and
    /// grow when a fixed-width column wraps a cell.
    let lineHeight: CGFloat
    /// The table itself (borders included), inside the marker gutters.
    let tableRect: CGRect
    /// The whole drawing area: table plus gutters.
    let size: CGSize

    var columnCount: Int { columnLeft.count - 1 }
    var rowCount: Int { rowTop.count - 1 }

    /// Height of `row`'s box (inside the borders).
    func rowHeight(_ row: Int) -> CGFloat { rowTop[row + 1] - Self.borderWidth - rowTop[row] }

    /// Measures formatted cells (row 0 = header) and lays out the grid.
    /// `widths` (one per column, missing = auto) fixes column boxes;
    /// percentages are of `availableWidth`.
    init(cells: [[NSAttributedString]], columnCount: Int, baseFont: PlatformFont,
         widths: [MarkdownTable.ColumnWidth] = [], availableWidth: CGFloat = 0) {
        let b = Self.borderWidth, h = Self.cellHPadding, v = Self.cellVPadding
        let baseLineHeight = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)

        // Column content widths: fixed ones from the attribute, the rest fit their widest cell.
        var contentWidths = [CGFloat](repeating: Self.minColumnContentWidth, count: columnCount)
        var fixed = [Bool](repeating: false, count: columnCount)
        for i in 0..<columnCount {
            let box: CGFloat?
            switch i < widths.count ? widths[i] : .auto {
            case .auto: box = nil
            case .points(let p): box = p
            case .percent(let p): box = availableWidth > 0 ? availableWidth * p / 100 : nil
            }
            if let box {
                contentWidths[i] = max(Self.minColumnContentWidth, floor(box - 2 * h - b))
                fixed[i] = true
            }
        }
        var maxLineHeight = baseLineHeight
        for row in cells {
            for (i, cell) in row.enumerated() where i < columnCount {
                let size = cell.size()
                if !fixed[i] { contentWidths[i] = max(contentWidths[i], ceil(size.width)) }
                maxLineHeight = max(maxLineHeight, ceil(size.height))
            }
        }
        lineHeight = maxLineHeight

        // Row heights: one line, or more where a fixed column wraps.
        var rowHeights: [CGFloat] = []
        for row in cells {
            var height = lineHeight
            for (i, cell) in row.enumerated() where i < columnCount && fixed[i] && cell.length > 0 {
                let wrapped = Self.wrapping(cell).boundingRect(
                    with: CGSize(width: contentWidths[i], height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                )
                height = max(height, ceil(wrapped.height))
            }
            rowHeights.append(height + 2 * v)
        }

        let origin = CGPoint(x: 0, y: Self.gutter.top)
        var left = [origin.x + b]
        for w in contentWidths { left.append(left.last! + w + 2 * h + b) }
        columnLeft = left
        var top = [origin.y + b]
        for height in rowHeights { top.append(top.last! + height + b) }
        rowTop = top
        tableRect = CGRect(x: origin.x, y: origin.y, width: left.last! - origin.x, height: top.last! - origin.y)
        size = CGSize(width: tableRect.maxX + Self.gutter.right, height: tableRect.maxY + Self.gutter.bottom)
    }

    /// `cell` set to wrap by words (fixed-width columns).
    static func wrapping(_ cell: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: cell)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The cell's box inside the borders.
    func cellRect(row: Int, column: Int) -> CGRect {
        CGRect(
            x: columnLeft[column], y: rowTop[row],
            width: columnLeft[column + 1] - Self.borderWidth - columnLeft[column],
            height: rowHeight(row)
        )
    }

    /// The text area of a cell (box minus padding).
    func contentRect(row: Int, column: Int) -> CGRect {
        cellRect(row: row, column: column).insetBy(dx: Self.cellHPadding, dy: Self.cellVPadding)
    }

    /// Frame for the cell editor: the first line of the cell's text area,
    /// widened to fit `textWidth` (growing away from the alignment edge) but
    /// kept inside the table.
    func editorFrame(row: Int, column: Int, textWidth: CGFloat, alignment: MarkdownTable.Alignment) -> CGRect {
        var frame = contentRect(row: row, column: column)
        frame.size.height = lineHeight
        let extra = ceil(textWidth) - frame.width
        guard extra > 0 else { return frame }
        switch alignment {
        case .none, .left: frame.size.width += extra
        case .right: frame.origin.x -= extra; frame.size.width += extra
        case .center: frame.origin.x -= extra / 2; frame.size.width += extra
        }
        let inner = tableRect.insetBy(dx: Self.borderWidth, dy: 0)
        if frame.width > inner.width { return CGRect(x: inner.minX, y: frame.minY, width: inner.width, height: frame.height) }
        if frame.minX < inner.minX { frame.origin.x = inner.minX }
        if frame.maxX > inner.maxX { frame.origin.x = inner.maxX - frame.width }
        return frame
    }

    /// Cell under `point` (top-left-origin drawing coordinates); borders count
    /// toward the cell to their right / below. nil outside the table.
    func cell(at point: CGPoint) -> (row: Int, column: Int)? {
        guard tableRect.contains(point) else { return nil }
        let column = (columnLeft.lastIndex { $0 <= point.x } ?? 0)
        let row = (rowTop.lastIndex { $0 <= point.y } ?? 0)
        return (min(max(row, 0), rowCount - 1), min(max(column, 0), columnCount - 1))
    }

    /// Width of column `column`'s box, its right border included.
    func columnWidth(_ column: Int) -> CGFloat { columnLeft[column + 1] - columnLeft[column] }

    /// The inner column border (1…columnCount, last = right edge) within
    /// `tolerance` of `x`, for resizing; only over the table's rows.
    func columnBorder(near point: CGPoint, tolerance: CGFloat = 4) -> Int? {
        guard point.y >= tableRect.minY, point.y <= tableRect.maxY else { return nil }
        for i in 1...columnCount where abs(columnLeft[i] - Self.borderWidth / 2 - point.x) <= tolerance { return i }
        return nil
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
    /// What `%` column widths are a share of.
    let availableWidth: CGFloat

    init(table: MarkdownTable, sourceRange: NSRange, layout: TableGridLayout, image: PlatformImage, availableWidth: CGFloat = 0) {
        self.table = table
        self.sourceRange = sourceRange
        self.layout = layout
        self.image = image
        self.availableWidth = availableWidth
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
        let table = layout.tableRect
        // Resolve under the real appearance: `.withAlphaComponent()` freezes a dynamic color otherwise.
        let muted = theme.mutedText.mdResolved(in: appearance)
        let borderColor = muted.withAlphaComponent(0.5)
        let headerFill = muted.withAlphaComponent(0.08)

        return PlatformImage.mdDrawing(size: layout.size) {
            headerFill.setFill()
            PlatformBezierPath(rect: CGRect(x: table.minX + b, y: table.minY + b, width: table.width - 2 * b, height: layout.rowHeight(0))).fill()

            borderColor.setStroke()
            let outer = PlatformBezierPath(rect: table.insetBy(dx: b / 2, dy: b / 2))
            outer.lineWidth = b
            outer.stroke()

            let separators = PlatformBezierPath()
            separators.lineWidth = b
            for i in 1..<layout.columnCount {
                let x = layout.columnLeft[i] - b / 2
                separators.move(to: CGPoint(x: x, y: table.minY))
                separators.line(to: CGPoint(x: x, y: table.maxY))
            }
            for i in 1..<layout.rowCount {
                let y = layout.rowTop[i] - b / 2
                separators.move(to: CGPoint(x: table.minX, y: y))
                separators.line(to: CGPoint(x: table.maxX, y: y))
            }
            separators.stroke()

            for (row, rowCells) in cells.enumerated() {
                for (col, cell) in rowCells.enumerated() where col < layout.columnCount {
                    let aligned = NSMutableAttributedString(attributedString: cell)
                    aligned.addAttribute(
                        .paragraphStyle,
                        value: tableCellParagraphStyle(alignments[col], wraps: true),
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

    static func tableCellParagraphStyle(_ alignment: MarkdownTable.Alignment, wraps: Bool = false) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = tableTextAlignment(alignment)
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byClipping
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
