//
//  MarkdownStyler+Tables.swift
//  MarkdownEngine
//
//  GFM tables. The table is parsed into a `MarkdownTable`, laid out by
//  `TableGridLayout`, and rendered to an image; its source glyphs collapse
//  to a single anchor line that reserves the table's height. Every table is
//  tagged for the platform's grid overlay (`TableGridView` / `TableGridUIView`),
//  which draws the image and edits cells in place. With the
//  caret inside the table ("Edit as Markdown"), the raw pipe source shows.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

extension MarkdownStyler {

    /// Whether this platform overlays an editable grid on rendered tables.
    static var tableGridSupported: Bool { true }

    static func styleTables(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // Per-content occurrence counter so identical tables get distinct sourceIDs.
        var occurrenceByContentHash: [Int: Int] = [:]
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .table {
            // Tokenizer already drops tables overlapping fenced code, so no re-check here.
            attrs.append((token.range, [.spellingState: 0]))

            let source = ctx.nsText.substring(with: token.range)
            guard let table = MarkdownTable(source: source) else { continue }

            // Advance occurrence index even for active tables so inactive duplicates stay stable.
            let contentHash = stableTableContentHash(for: source)
            let occurrenceIndex = occurrenceByContentHash[contentHash, default: 0]
            occurrenceByContentHash[contentHash] = occurrenceIndex + 1

            let isActive = ctx.activeTokenIndices.contains(idx)
            if isActive {
                // Caret inside the table — show editable source, pipes muted like other syntax.
                let muted = ctx.configuration.theme.mutedText
                let body = ctx.configuration.theme.bodyText
                attrs.append((token.range, [.foregroundColor: body, .font: ctx.baseFont]))
                // Mute each `|` so the structure stays legible while editing.
                let end = NSMaxRange(token.range)
                var i = token.range.location
                while i < end {
                    if ctx.nsText.character(at: i) == 0x7C {   // '|'
                        attrs.append((NSRange(location: i, length: 1), [.foregroundColor: muted]))
                    }
                    i += 1
                }
                // The trailing `{cols="…"}` line is syntax too.
                let lastLine = ctx.nsText.lineRange(for: NSRange(location: max(token.range.location, end - 1), length: 0))
                let lastText = ctx.nsText.substring(with: NSIntersectionRange(lastLine, token.range))
                if MarkdownTable.attributeLine(lastText) != nil {
                    attrs.append((NSIntersectionRange(lastLine, token.range), [.foregroundColor: muted]))
                }
                continue
            }

            let theme = ctx.configuration.theme
            let cells = ([table.header] + table.rows).enumerated().map { row, rowCells in
                rowCells.map {
                    formattedCellString(
                        $0, baseFont: ctx.baseFont, header: row == 0, theme: theme,
                        codeBackgroundColor: ctx.codeBackgroundColor, latex: ctx.services.latex
                    )
                }
            }
            let containerWidth = effectiveContainerWidth(for: ctx)
            let availableWidth = containerWidth - TableGridLayout.gutter.right
            let layout = TableGridLayout(
                cells: cells, columnCount: table.columnCount, baseFont: ctx.baseFont,
                widths: table.columnWidths, availableWidth: availableWidth
            )
            // Resolve table colors under the text view's real appearance.
            let image = renderTable(
                cells: cells, alignments: table.alignments, layout: layout,
                theme: theme, appearance: Self.tableRenderAppearance(ctx)
            )
            let imageBounds = CGRect(origin: .zero, size: image.size)
            // The table itself decides; its marker gutter may overhang.
            let isWide = layout.tableRect.maxX > containerWidth + 0.5
            let sourceID = stableTableSourceID(for: source, occurrenceIndex: occurrenceIndex)
            // Overlay mode for the interactive grid, and for wide tables (horizontal scroll).
            let mode: RenderedStandaloneBlockMode = (isWide || tableGridSupported)
                ? .collapsedSourceScrollable(
                    markerTexts: [],
                    displayWidth: containerWidth,
                    sourceID: sourceID,
                    reservesScroller: isWide
                )
                : .collapsedSource(markerTexts: [])
            let rendered = appendRenderedStandaloneBlock(
                for: token,
                rawContent: source,
                image: image,
                imageBounds: imageBounds,
                // The marker gutters above and below take most of the usual spacing.
                paragraphSpacingBefore: max(0, ctx.baseDefaultLineHeight * 0.5 - TableGridLayout.gutter.top),
                paragraphSpacing: max(0, ctx.baseDefaultLineHeight * 0.5 - TableGridLayout.gutter.bottom),
                alignment: .left,
                mode: mode,
                ctx: ctx,
                attrs: &attrs
            )
            if rendered {
                let info = TableRenderInfo(table: table, sourceRange: token.range, layout: layout, image: image, availableWidth: availableWidth)
                attrs.append((token.range, [.tableRenderInfo: info]))
            }
        }
        return attrs
    }

    // MARK: - Inline-formatted cell strings

    /// Raw cell → `NSAttributedString`: inline markdown applied, markers stripped, LaTeX as attachments.
    static func formattedCellString(
        _ raw: String,
        baseFont: PlatformFont,
        header: Bool,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: PlatformColor,
        latex: any LatexRenderer
    ) -> NSAttributedString {
        let descriptor = baseFont.fontDescriptor
        let pointSize = baseFont.pointSize
        let codeFont = PlatformFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        let startFont = header
            ? (PlatformFont.md(descriptor: descriptor, traits: .bold, size: pointSize) ?? baseFont)
            : baseFont
        let out = NSMutableAttributedString()
        appendInlineCell(
            InlineParser.parse(raw), in: raw as NSString, into: out,
            font: startFont, baseDescriptor: descriptor, pointSize: pointSize,
            codeFont: codeFont, theme: theme, codeBackgroundColor: codeBackgroundColor, latex: latex
        )
        return out
    }

    /// Compose `current`'s bold/italic traits with `kind` so nested emphasis stacks (italic+bold).
    private static func composeEmphasis(
        _ current: PlatformFont, _ kind: EmphasisKind,
        baseDescriptor: PlatformFontDescriptor, pointSize: CGFloat
    ) -> PlatformFont {
        var traits = current.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
        switch kind {
        case .bold: traits.insert(.bold)
        case .italic: traits.insert(.italic)
        case .boldItalic: traits.formUnion([.bold, .italic])
        }
        return PlatformFont.md(descriptor: baseDescriptor, traits: traits, size: pointSize) ?? current
    }

    /// Walk the inline AST into marker-stripped runs; LaTeX as attachments, links/images emitted raw.
    private static func appendInlineCell(
        _ nodes: [InlineNode],
        in ns: NSString,
        into out: NSMutableAttributedString,
        font: PlatformFont,
        baseDescriptor: PlatformFontDescriptor,
        pointSize: CGFloat,
        codeFont: PlatformFont,
        theme: MarkdownEditorTheme,
        codeBackgroundColor: PlatformColor,
        latex: any LatexRenderer
    ) {
        func recurse(_ children: [InlineNode], _ f: PlatformFont) {
            appendInlineCell(children, in: ns, into: out, font: f, baseDescriptor: baseDescriptor,
                             pointSize: pointSize, codeFont: codeFont, theme: theme,
                             codeBackgroundColor: codeBackgroundColor, latex: latex)
        }
        func appendPlain(_ range: NSRange, _ f: PlatformFont) {
            out.append(NSAttributedString(string: ns.substring(with: range),
                                          attributes: [.font: f, .foregroundColor: theme.bodyText]))
        }
        for node in nodes {
            switch node {
            case .text(let r):
                appendPlain(r, font)
            case .escape(_, let character, _):
                appendPlain(character, font)
            case .emphasis(let kind, _, _, let children):
                recurse(children, composeEmphasis(font, kind, baseDescriptor: baseDescriptor, pointSize: pointSize))
            case .strikethrough(_, _, let children):
                let start = out.length
                recurse(children, font)
                if out.length > start {
                    out.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: theme.bodyText
                    ], range: NSRange(location: start, length: out.length - start))
                }
            case .code(_, let content):
                out.append(NSAttributedString(string: ns.substring(with: content), attributes: [
                    .font: codeFont, .backgroundColor: codeBackgroundColor, .foregroundColor: theme.bodyText
                ]))
            case .inlineLatex(let range, let content, _):
                if let entry = latex.render(latex: ns.substring(with: content), fontSize: pointSize, theme: theme) {
                    let attachment = NSTextAttachment()
                    attachment.image = entry.image
                    attachment.bounds = CGRect(x: 0, y: entry.baselineOffset,
                                               width: entry.size.width, height: entry.size.height)
                    out.append(NSAttributedString(attachment: attachment))
                } else {
                    appendPlain(range, font)   // renderer unavailable → keep raw `$…$`
                }
            case .link(let range, _, _, _, _),
                 .image(let range, _, _, _):
                appendPlain(range, font)
            }
        }
    }

    static func effectiveContainerWidth(for ctx: StylingContext) -> CGFloat {
        if let container = ctx.layoutBridge?.firstTextContainer {
            let raw = container.size.width
            if raw.isFinite, raw > 0, raw < 100_000 { return raw }
            if let textView = Self.hostTextView(container) {
                let insetWidth = Self.horizontalInset(textView)
                let usable = textView.bounds.width - insetWidth
                if usable.isFinite, usable > 0 { return usable }
                let frameUsable = textView.frame.width - insetWidth
                if frameUsable.isFinite, frameUsable > 0 { return frameUsable }
            }
        }
        return 500
    }

    /// Content-only hash; intentionally collides for identical tables — disambiguated by occurrence index.
    static func stableTableContentHash(for source: String) -> Int {
        var hasher = Hasher()
        hasher.combine("table-overlay-v1")
        hasher.combine(source)
        return hasher.finalize()
    }

    /// Per-instance ID = (content, nth-occurrence); stable across re-styles so scroll offsets persist.
    static func stableTableSourceID(for source: String, occurrenceIndex: Int) -> Int {
        var hasher = Hasher()
        hasher.combine("table-overlay-v2")
        hasher.combine(source)
        hasher.combine(occurrenceIndex)
        return hasher.finalize()
    }
}

extension MarkdownStyler {
    /// Appearance to resolve table colors under: the text view's own, else the app's.
    static func tableRenderAppearance(_ ctx: StylingContext) -> PlatformAppearance {
        #if os(macOS)
        return ctx.layoutBridge?.firstTextContainer?.textView?.effectiveAppearance ?? .mdCurrent
        #else
        return ctx.layoutBridge?.textView?.traitCollection ?? .mdCurrent
        #endif
    }
}

extension MarkdownStyler {
    static func hostTextView(_ container: NSTextContainer) -> PlatformTextView? {
        #if os(macOS)
        return container.textView
        #else
        return container.textLayoutManager?.mdHost as? PlatformTextView
        #endif
    }

    /// Total left + right text-container inset.
    static func horizontalInset(_ textView: PlatformTextView) -> CGFloat {
        #if os(macOS)
        return textView.textContainerInset.width * 2
        #else
        return textView.textContainerInset.left + textView.textContainerInset.right
        #endif
    }
}
