//
//  MarkdownStyler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Applies the Markdown look (bold, links, code, headings, etc.). Most styling
// is now produced by the AST-native styler (`MarkdownASTStyler`); this type
// builds the `StylingContext` and runs the PlatformImage rendering passes that still
// consume tokens:
//   - MarkdownStyler+Latex.swift   (block + inline LaTeX rendering)
//   - MarkdownStyler+Images.swift  (image links)
//   - MarkdownStyler+Tables.swift  (rendered tables)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

// MARK: - Styling Context

extension MarkdownStyler {
    struct StylingContext {
        let nsText: NSString
        let tokens: [MarkdownToken]
        let codeTokens: [MarkdownToken]
        let activeTokenIndices: Set<Int>
        let baseFont: PlatformFont
        let layoutBridge: LayoutBridge?
        let baseDefaultLineHeight: CGFloat
        let codeBackgroundColor: PlatformColor
        let latexMarkerFont: PlatformFont
        let configuration: MarkdownEditorConfiguration

        var services: MarkdownEditorServices { configuration.services }
    }
}

typealias StyledRange = (range: NSRange, attributes: [NSAttributedString.Key: Any])

// MARK: - Public API

enum MarkdownStyler {

    /// Collapses styler output into non-overlapping runs, ascending, so a caller can
    /// write each character range to the text storage exactly once.
    ///
    /// The styler emits ranges pass by pass, so they arrive unordered and heavily
    /// overlapping. Applying them with one `addAttribute` per key per range mutates
    /// the storage once per pair — 89,916 times on a 346k-char note — and every
    /// mutation re-splits the attribute-run array, so the cost of a single call grows
    /// with the runs already present: measured 0.54µs/call on a 437-char note against
    /// 213µs/call on the big one. That quadratic was 19.1s of a 21s open. Writing
    /// left to right instead only ever splits the trailing run.
    ///
    /// Semantics are identical to the loop it replaces: later ranges win per key, and
    /// `base` fills what no range covers (the caller applies it to the whole document
    /// first, so each returned run must carry it too — `setAttributes` replaces).
    static func flattenedRuns(
        _ ranges: [StyledRange],
        base: [NSAttributedString.Key: Any],
        documentLength: Int
    ) -> [StyledRange] {
        // (position, isStart, emission index). Ends sort before starts at the same
        // position so a range ending where the next begins doesn't briefly overlap it.
        var events: [(pos: Int, isStart: Bool, idx: Int)] = []
        events.reserveCapacity(ranges.count * 2)
        for (i, styled) in ranges.enumerated() {
            let r = styled.range
            guard r.location != NSNotFound, r.location >= 0, r.length > 0,
                  NSMaxRange(r) <= documentLength else { continue }
            events.append((r.location, true, i))
            events.append((NSMaxRange(r), false, i))
        }
        guard !events.isEmpty else { return [] }
        events.sort { a, b in
            if a.pos != b.pos { return a.pos < b.pos }
            if a.isStart != b.isStart { return !a.isStart }
            return a.idx < b.idx
        }

        var runs: [StyledRange] = []
        runs.reserveCapacity(min(events.count, 4096))
        // Emission indices of the ranges covering the current position, kept ascending
        // so merging them in order reproduces "later range wins".
        var active: [Int] = []
        var cursor = events[0].pos
        var i = 0
        while i < events.count {
            let pos = events[i].pos
            if pos > cursor, !active.isEmpty {
                var attrs = base
                for idx in active {
                    attrs.merge(ranges[idx].attributes) { _, newer in newer }
                }
                let run = NSRange(location: cursor, length: pos - cursor)
                // Adjacent runs frequently carry identical attributes — one styling
                // pass emits a separate range per character — so coalesce before the
                // write instead of paying a storage mutation per character.
                if let last = runs.last, NSMaxRange(last.range) == run.location,
                   (last.attributes as NSDictionary).isEqual(to: attrs) {
                    runs[runs.count - 1].range.length += run.length
                } else {
                    runs.append((run, attrs))
                }
            }
            while i < events.count, events[i].pos == pos {
                let event = events[i]
                if event.isStart {
                    let slot = active.firstIndex { $0 > event.idx } ?? active.count
                    active.insert(event.idx, at: slot)
                } else if let slot = active.firstIndex(of: event.idx) {
                    active.remove(at: slot)
                }
                i += 1
            }
            cursor = pos
        }
        return runs
    }

    static func styleAttributes(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge? = nil,
        caretLocation: Int,
        activeTokenIndices: Set<Int>,
        precomputedTokens: [MarkdownToken]? = nil,
        scopedRanges: [NSRange]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let tokens = precomputedTokens ?? MarkdownTokenizer.parseTokensViaAST(in: text)
        if configuration.renderingMode == .source {
            return MarkdownSourceStyler.styleAttributes(
                text: text, fontSize: fontSize, tokens: tokens,
                scopedRanges: scopedRanges, configuration: configuration
            )
        }
        let nsText = text as NSString
        let codeTokens = tokens.filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        let baseFont = PlatformFont.md(named: fontName, size: fontSize)
        let baseDefaultLineHeight = ceil(
            layoutBridge?.defaultLineHeight(for: baseFont)
            ?? (baseFont.ascender - baseFont.descender + baseFont.leading)
        )
        let codeBackgroundColor = configuration.services.syntaxHighlighter.backgroundColor()
        let hiddenMarkerSize = configuration.markers.hiddenMarkerFontSize
        let ctx = StylingContext(
            nsText: nsText,
            tokens: tokens,
            codeTokens: codeTokens,
            activeTokenIndices: activeTokenIndices,
            baseFont: baseFont,
            layoutBridge: layoutBridge,
            baseDefaultLineHeight: baseDefaultLineHeight,
            codeBackgroundColor: codeBackgroundColor,
            latexMarkerFont: PlatformFont.md(named: fontName, size: hiddenMarkerSize),
            configuration: configuration
        )

        var result: [StyledRange] = []
        // AST-native styler handles everything but PlatformImage rendering (incl. the composition fixes).
        result += MarkdownASTStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: fontSize,
            caretLocation: caretLocation,
            scopedRanges: scopedRanges, configuration: configuration
        )
        // PlatformImage rendering reuses the existing, proven machinery.
        result += styleBlockLatex(ctx)
        result += styleInlineLatex(ctx)
        result += styleImageLinks(ctx)
        result += styleLinkPreviews(ctx)
        result += styleTables(ctx)
        result += styleFrontmatter(ctx)
        return result
    }
}

// MARK: - Shared helpers used by multiple styling extensions

extension MarkdownStyler {

    static func appendSecondaryMarkers(
        for token: MarkdownToken,
        to attrs: inout [StyledRange],
        theme: MarkdownEditorTheme
    ) {
        token.markerRanges.forEach {
            attrs.append(($0, [.foregroundColor: theme.mutedText]))
        }
    }

    enum RenderedStandaloneBlockMode {
        case collapsedSource(markerTexts: [String])
        case visibleSource(imageGap: CGFloat)
        /// Overlay mode (table grid / wide tables): anchor reserves container width, tagged by sourceID; wide tables also reserve a scroller strip.
        case collapsedSourceScrollable(
            markerTexts: [String],
            displayWidth: CGFloat,
            sourceID: Int,
            reservesScroller: Bool
        )
    }

    static func appendRenderedStandaloneBlock(
        for token: MarkdownToken,
        rawContent: String,
        image: PlatformImage,
        imageBounds: CGRect,
        paragraphSpacingBefore: CGFloat,
        paragraphSpacing: CGFloat,
        alignment: NSTextAlignment,
        leadingIndent: CGFloat = 0,
        mode: RenderedStandaloneBlockMode,
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) -> Bool {
        guard let paraRange = token.standaloneParagraphRange(in: ctx.nsText) else { return false }

        let para = NSMutableParagraphStyle()
        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        para.paragraphSpacingBefore = max(para.paragraphSpacingBefore, paragraphSpacingBefore)
        para.alignment = alignment
        // Offsets the anchor glyph (and so the image). Paragraph alignment
        // can't place a collapsed block: the hidden source has no width.
        para.firstLineHeadIndent = leadingIndent
        para.headIndent = leadingIndent

        switch mode {
        case .collapsedSource(let markerTexts):
            emitCollapsedAttrs(
                token: token,
                rawContent: rawContent,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacing: paragraphSpacing,
                para: para,
                paraRange: paraRange,
                advanceWidth: imageBounds.width,
                neededLineHeight: imageBounds.height,
                extraAnchorAttrs: [:],
                markerTexts: markerTexts,
                ctx: ctx,
                attrs: &attrs
            )

        case .collapsedSourceScrollable(let markerTexts, let displayWidth, let sourceID, let reservesScroller):
            let scrollerStrip = reservesScroller ? MarkdownTextLayoutFragment.scrollableBlockScrollerStrip : 0
            let totalHeight = imageBounds.height + scrollerStrip
            emitCollapsedAttrs(
                token: token,
                rawContent: rawContent,
                image: image,
                imageBounds: imageBounds,
                paragraphSpacing: paragraphSpacing,
                para: para,
                paraRange: paraRange,
                advanceWidth: displayWidth,
                neededLineHeight: totalHeight,
                extraAnchorAttrs: [
                    .scrollableBlockNaturalWidth: imageBounds.width,
                    .scrollableBlockSourceID: sourceID,
                    .scrollableBlockTotalHeight: totalHeight,
                    .scrollableBlockFullRange: NSValue(range: paraRange)
                ],
                markerTexts: markerTexts,
                ctx: ctx,
                attrs: &attrs
            )

        case .visibleSource(let imageGap):
            para.minimumLineHeight = max(para.minimumLineHeight, baseLineHeight)
            para.maximumLineHeight = max(para.maximumLineHeight, baseLineHeight)
            para.paragraphSpacing = max(para.paragraphSpacing, imageBounds.height + imageGap + paragraphSpacing)

            attrs.append((paraRange, [.paragraphStyle: para]))
            attrs.append((token.range, [
                .latexImage: image,
                .latexBounds: NSValue(mdRect: imageBounds),
                .latexIsBlock: true,
                .latexBlockOffsetY: baseLineHeight + imageGap
            ]))
            appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
        }

        return true
    }

    /// Shared body for collapsed-source modes; hides raw source, plants image on anchor.
    private static func emitCollapsedAttrs(
        token: MarkdownToken,
        rawContent: String,
        image: PlatformImage,
        imageBounds: CGRect,
        paragraphSpacing: CGFloat,
        para: NSMutableParagraphStyle,
        paraRange: NSRange,
        advanceWidth: CGFloat,
        neededLineHeight: CGFloat,
        extraAnchorAttrs: [NSAttributedString.Key: Any],
        markerTexts: [String],
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) {
        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        let resolved = max(para.minimumLineHeight, neededLineHeight, baseLineHeight)
        para.minimumLineHeight = resolved
        para.maximumLineHeight = max(para.maximumLineHeight, resolved)
        para.paragraphSpacing = max(para.paragraphSpacing, paragraphSpacing)
        para.lineBreakMode = .byClipping

        let collapsedPara = NSMutableParagraphStyle()
        collapsedPara.maximumLineHeight = 1
        collapsedPara.paragraphSpacing = 0
        collapsedPara.paragraphSpacingBefore = 0

        let leadingWhitespaceUnits = rawContent.utf16.prefix { codeUnit in
            guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }.count
        let contentEnd = NSMaxRange(token.contentRange)
        let anchorLocation = min(token.contentRange.location + leadingWhitespaceUnits, contentEnd - 1)

        var paragraphAttributes: [StyledRange] = []
        ctx.nsText.enumerateSubstrings(in: paraRange, options: .byParagraphs) { _, _, enclosingRange, _ in
            if NSLocationInRange(anchorLocation, enclosingRange) {
                paragraphAttributes.append((enclosingRange, [.paragraphStyle: para]))
            } else {
                paragraphAttributes.append((enclosingRange, [.paragraphStyle: collapsedPara]))
            }
        }
        attrs.append(contentsOf: paragraphAttributes)

        if leadingWhitespaceUnits > 0 {
            let leadingRange = NSRange(location: token.contentRange.location, length: leadingWhitespaceUnits)
            let leadingText = ctx.nsText.substring(with: leadingRange)
            attrs.append((leadingRange, [
                .foregroundColor: PlatformColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.textWidth(leadingText, font: ctx.latexMarkerFont)
            ]))
        }

        let anchorRange = NSRange(location: anchorLocation, length: 1)
        let anchorChar = ctx.nsText.substring(with: anchorRange)
        var anchorAttrs: [NSAttributedString.Key: Any] = [
            .latexImage: image,
            .latexBounds: NSValue(mdRect: imageBounds),
            .latexIsBlock: true,
            .foregroundColor: PlatformColor.clear,
            .font: ctx.latexMarkerFont,
            .kern: advanceWidth - HeadingHelpers.textWidth(anchorChar, font: ctx.latexMarkerFont)
        ]
        for (key, value) in extraAnchorAttrs { anchorAttrs[key] = value }
        attrs.append((anchorRange, anchorAttrs))

        let trailingStart = anchorLocation + 1
        let trailingLength = contentEnd - trailingStart
        if trailingLength > 0 {
            let trailingRange = NSRange(location: trailingStart, length: trailingLength)
            let trailingText = ctx.nsText.substring(with: trailingRange)
            attrs.append((trailingRange, [
                .foregroundColor: PlatformColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.textWidth(trailingText, font: ctx.latexMarkerFont)
            ]))
        }

        for (index, markerRange) in token.markerRanges.enumerated() {
            let markerText = markerTexts.indices.contains(index)
                ? markerTexts[index]
                : ctx.nsText.substring(with: markerRange)
            attrs.append((markerRange, [
                .foregroundColor: PlatformColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.textWidth(markerText, font: ctx.latexMarkerFont)
            ]))
        }

        let preTokenLength = token.range.location - paraRange.location
        if preTokenLength > 0 {
            let preTokenRange = NSRange(location: paraRange.location, length: preTokenLength)
            let preTokenText = ctx.nsText.substring(with: preTokenRange)
            attrs.append((preTokenRange, [
                .foregroundColor: PlatformColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: -HeadingHelpers.textWidth(preTokenText, font: ctx.latexMarkerFont)
            ]))
        }
    }
}

// MARK: - Whole-document & inline-only styling kept inline (small helpers)

extension MarkdownStyler {

    /// Line range if `location` is on a thematic-break line (3+ `-`/`*`/`_`), else nil; drives HR restyle.
    static func hrLineRange(at location: Int, in text: String) -> NSRange? {
        let nsText = text as NSString
        let safeLoc = max(0, min(location, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
        let line = nsText.substring(with: lineRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.range(
            of: #"^[ \t]*(-{3,}|\*{3,}|_{3,})[ \t]*$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return lineRange
    }
}
