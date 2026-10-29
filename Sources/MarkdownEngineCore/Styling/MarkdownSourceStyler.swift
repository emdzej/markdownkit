//
//  MarkdownSourceStyler.swift
//  MarkdownEngine
//
//  `.source` rendering mode: markdown shown exactly as typed in a monospaced
//  font, with its syntax highlighted. Nothing hides or renders, so every
//  attribute here is a font trait or a color — no images, kerning or
//  paragraph tricks. Walks the same document AST as the formatted styler.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

enum MarkdownSourceStyler {

    static func styleAttributes(
        text: String,
        fontSize: CGFloat,
        tokens: [MarkdownToken],
        scopedRanges: [NSRange]? = nil,
        configuration: MarkdownEditorConfiguration
    ) -> [StyledRange] {
        let ns = text as NSString
        let theme = configuration.theme
        let style = configuration.source
        let ctx = Ctx(
            ns: ns,
            font: style.font(size: fontSize),
            accent: style.headingColor ?? theme.link,
            theme: theme,
            style: style,
            codeBackground: configuration.services.syntaxHighlighter.backgroundColor(),
            highlighter: configuration.services.syntaxHighlighter,
            scopedRanges: scopedRanges
        )
        var attrs: [StyledRange] = []
        for block in DocumentAST.parse(text, scopedRanges: scopedRanges) where ctx.inScope(block.range) {
            styleBlock(block, ctx: ctx, into: &attrs)
        }
        // `{…}` attribute blocks after images/links come from the inline tokens.
        for token in tokens where ctx.inScope(token.range) {
            if token.kind == .frontmatter {
                attrs += MarkdownStyler.frontmatterSourceAttributes(token, ns: ns, theme: theme, source: style)
                attrs.append((token.range, [.spellingState: 0]))
            }
        }
        return attrs
    }

    private struct Ctx {
        let ns: NSString
        let font: PlatformFont
        let accent: PlatformColor
        let theme: MarkdownEditorTheme
        let style: SourceModeStyle
        let codeBackground: PlatformColor
        let highlighter: any SyntaxHighlighter
        let scopedRanges: [NSRange]?

        func inScope(_ r: NSRange) -> Bool {
            guard let scopedRanges else { return true }
            return scopedRanges.contains { NSIntersectionRange($0, r).length > 0 || ($0.length == 0 && NSLocationInRange($0.location, r)) }
        }
        var muted: [NSAttributedString.Key: Any] { [.foregroundColor: theme.mutedText] }
    }

    // MARK: Blocks

    private static func styleBlock(_ block: BlockNode, ctx: Ctx, into attrs: inout [StyledRange]) {
        switch block {
        case .paragraph(_, let inlines):
            styleInlines(inlines, font: ctx.font, ctx: ctx, into: &attrs)

        case .heading(_, let range, let markers, let inlines):
            let bold = adding(.bold, to: ctx.font)
            attrs.append((trimmedLine(range, ctx.ns), [.font: bold, .foregroundColor: ctx.accent]))
            for marker in markers { attrs.append((marker, [.foregroundColor: ctx.accent.withAlphaComponent(0.6)])) }
            styleInlines(inlines, font: bold, ctx: ctx, into: &attrs)

        case .blockquote(let range, let inlines):
            styleQuoteMarkers(range, ctx: ctx, into: &attrs)
            styleInlines(inlines, font: ctx.font, ctx: ctx, into: &attrs)

        case .list(_, let items):
            for item in items {
                attrs.append((item.marker, [.foregroundColor: ctx.accent]))
                if let box = item.checkbox { attrs.append((box, [.foregroundColor: ctx.accent])) }
                if item.checked, item.contentRange.length > 0 {
                    attrs.append((item.contentRange, [.foregroundColor: ctx.theme.mutedText]))
                }
                styleInlines(item.inlines, font: ctx.font, ctx: ctx, into: &attrs)
            }

        case .codeBlock(let range):
            styleCodeBlock(range, ctx: ctx, into: &attrs)

        case .blockLatex(let range):
            attrs.append((range, [.foregroundColor: ctx.style.codeColor, .spellingState: 0]))

        case .table(let range):
            styleTable(range, ctx: ctx, into: &attrs)

        case .thematicBreak(let range):
            attrs.append((trimmedLine(range, ctx.ns), ctx.muted))

        case .blank, .frontmatter:
            break   // frontmatter: from its token, shared with formatted mode
        }
    }

    private static func styleCodeBlock(_ range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        let ns = ctx.ns
        let open = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let lastLine = ns.lineRange(for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0))
        let hasClose = lastLine.location > open.location
        attrs.append((range, [.backgroundColor: ctx.codeBackground, .spellingState: 0]))
        attrs.append((trimmedLine(open, ns), ctx.muted))
        if hasClose { attrs.append((trimmedLine(lastLine, ns), ctx.muted)) }

        let contentStart = NSMaxRange(open)
        let contentEnd = hasClose ? lastLine.location : NSMaxRange(range)
        guard contentEnd > contentStart else { return }
        let content = NSRange(location: contentStart, length: contentEnd - contentStart)
        let fence = ns.substring(with: trimmedLine(open, ns))
        let language = fence.drop { $0 == "`" }.trimmingCharacters(in: .whitespaces)
        if let highlighted = ctx.highlighter.highlight(code: ns.substring(with: content), language: language.isEmpty ? nil : language) {
            highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, r, _ in
                guard let value else { return }
                attrs.append((NSRange(location: content.location + r.location, length: r.length), [.foregroundColor: value]))
            }
        }
    }

    /// `|` pipes and the `---|:--:` separator row muted; cells stay plain text.
    private static func styleTable(_ range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        let ns = ctx.ns
        attrs.append((range, [.spellingState: 0]))
        var cursor = range.location
        var lineIndex = 0
        while cursor < NSMaxRange(range) {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            defer { cursor = max(NSMaxRange(line), cursor + 1); lineIndex += 1 }
            if lineIndex == 1 {
                attrs.append((trimmedLine(line, ns), ctx.muted))
                continue
            }
            for i in line.location..<NSMaxRange(line) where ns.character(at: i) == 0x7C {   // |
                attrs.append((NSRange(location: i, length: 1), ctx.muted))
            }
            if lineIndex == 0 {
                attrs.append((trimmedLine(line, ns), [.font: adding(.bold, to: ctx.font)]))
            }
            styleFormulaLinks(in: trimmedLine(line, ns), ctx: ctx, into: &attrs)
        }
    }

    /// `[?](#SUM(C1:C2))` cells (MarkdownFormulas): link syntax muted, the formula in the code color.
    private static func styleFormulaLinks(in line: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        let ns = ctx.ns
        guard ns.substring(with: line).contains("](#") else { return }
        var cellStart = line.location
        var i = line.location
        while i <= NSMaxRange(line) {
            let atEnd = i == NSMaxRange(line)
            if !atEnd, ns.character(at: i) == 0x5C { i += 2; continue }     // escaped
            if atEnd || ns.character(at: i) == 0x7C {
                let cell = NSRange(location: cellStart, length: i - cellStart)
                if cell.length > 0, let match = MarkdownFormulas.linkMatch(in: ns.substring(with: cell)),
                   MarkdownFormulas.isFormula(match.formula) {
                    let link = NSRange(location: cell.location + match.range.location, length: match.range.length)
                    let formulaLength = (match.formula as NSString).length
                    let formula = NSRange(location: NSMaxRange(link) - 1 - formulaLength, length: formulaLength)
                    attrs.append((link, ctx.muted))
                    attrs.append((formula, [.foregroundColor: ctx.style.codeColor, .spellingState: 0]))
                }
                cellStart = i + 1
            }
            i += 1
        }
    }

    private static func styleQuoteMarkers(_ range: NSRange, ctx: Ctx, into attrs: inout [StyledRange]) {
        let ns = ctx.ns
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            defer { cursor = max(NSMaxRange(line), cursor + 1) }
            var i = line.location
            while i < NSMaxRange(line), ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 || ns.character(at: i) == 0x3E {
                if ns.character(at: i) == 0x3E { attrs.append((NSRange(location: i, length: 1), [.foregroundColor: ctx.accent])) }
                i += 1
            }
            let content = trimmedLine(NSRange(location: i, length: NSMaxRange(line) - i), ns)
            if content.length > 0 { attrs.append((content, [.foregroundColor: ctx.theme.mutedText])) }
        }
    }

    // MARK: Inlines

    private static func styleInlines(_ nodes: [InlineNode], font: PlatformFont, ctx: Ctx, into attrs: inout [StyledRange]) {
        for node in nodes {
            switch node {
            case .text:
                break

            case .emphasis(let kind, let range, let markers, let children):
                let composed = adding(MarkdownASTStyler.traits(for: kind), to: font)
                attrs.append((range, [.font: composed]))
                for marker in markers { attrs.append((marker, ctx.muted)) }
                styleInlines(children, font: composed, ctx: ctx, into: &attrs)

            case .strikethrough(let range, let markers, let children):
                attrs.append((range, [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                      .strikethroughColor: ctx.theme.mutedText]))
                for marker in markers { attrs.append((marker, ctx.muted)) }
                styleInlines(children, font: font, ctx: ctx, into: &attrs)

            case .code(let range, _):
                attrs.append((range, [.foregroundColor: ctx.style.codeColor, .backgroundColor: ctx.codeBackground,
                                      .spellingState: 0]))

            case .link(_, let textRange, let url, let markers, let children):
                attrs.append((textRange, [.foregroundColor: ctx.theme.link]))
                styleDestination(url, markers: markers, ctx: ctx, into: &attrs)
                styleInlines(children, font: font, ctx: ctx, into: &attrs)

            case .image(_, let alt, let url, let markers):
                attrs.append((alt, [.foregroundColor: ctx.theme.link]))
                styleDestination(url, markers: markers, ctx: ctx, into: &attrs)

            case .inlineLatex(let range, _, let markers):
                attrs.append((range, [.foregroundColor: ctx.style.codeColor, .spellingState: 0]))
                for marker in markers { attrs.append((marker, ctx.muted)) }

            case .escape(_, _, let marker):
                attrs.append((marker, ctx.muted))
            }
        }
    }

    /// `[`, `]`, `(url)` muted; a trailing `{…}` (the fifth marker) in the attribute color.
    private static func styleDestination(_ url: NSRange, markers: [NSRange], ctx: Ctx, into attrs: inout [StyledRange]) {
        for (i, marker) in markers.enumerated() {
            attrs.append((marker, i == 4 ? [.foregroundColor: ctx.style.attributeColor, .spellingState: 0] : ctx.muted))
        }
        guard url.length > 0 else { return }
        // `#SUM(C1:C2)`: a table formula (MarkdownFormulas), shown in the code color.
        let destination = ctx.ns.substring(with: url)
        if destination.hasPrefix("#"), MarkdownFormulas.isFormula(String(destination.dropFirst())) {
            attrs.append((url, [.foregroundColor: ctx.style.codeColor, .spellingState: 0]))
        } else {
            attrs.append((url, [.foregroundColor: ctx.theme.mutedText, .spellingState: 0]))
        }
    }

    // MARK: Helpers

    private static func adding(_ traits: PlatformFontDescriptor.SymbolicTraits, to font: PlatformFont) -> PlatformFont {
        MarkdownASTStyler.adding(traits, to: font)
    }

    /// `range` without its trailing line break.
    private static func trimmedLine(_ range: NSRange, _ ns: NSString) -> NSRange {
        var r = range
        while r.length > 0 {
            let c = ns.character(at: NSMaxRange(r) - 1)
            guard c == 0x0A || c == 0x0D else { break }
            r.length -= 1
        }
        return r
    }
}
