//
//  MarkdownHTML.swift
//  MarkdownEngine
//
//  The note as HTML, for printing and PDF export. It walks the same block and
//  inline parse the editor styles from, so what prints matches what's on
//  screen: frontmatter as a line of chips, `{…}` sizes and alignment on
//  images, `{.preview}` cards, table column widths from `{cols=…}`, formula
//  values, checklists, hidden `<!-- -->` lines, LaTeX as images.
//
//  The output is a body fragment; the embedder adds the page and its CSS
//  (class names below are prefixed `nmw-`).
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

public enum MarkdownHTML {

    /// What a `{.preview}` card shows.
    public struct LinkCard: Sendable {
        public var title: String
        public var summary: String?
        public var subtitle: String?
        /// `src` values (file URLs or data URIs).
        public var iconSource: String?
        public var imageSource: String?

        public init(title: String, summary: String? = nil, subtitle: String? = nil,
                    iconSource: String? = nil, imageSource: String? = nil) {
            self.title = title
            self.summary = summary
            self.subtitle = subtitle
            self.iconSource = iconSource
            self.imageSource = imageSource
        }
    }

    public struct Options {
        /// The `src` for an image destination as written (e.g. a file URL), or nil to leave it out.
        public var resolveImage: (String) -> String?
        /// The card for a `{.preview}` link's destination; nil prints a plain link.
        public var preview: (String) -> LinkCard?
        public var highlighter: SyntaxHighlighter?
        public var latex: LatexRenderer?
        /// Theme for LaTeX ink and code colors.
        public var theme: MarkdownEditorTheme
        public var bodyFontSize: CGFloat
        public var images: ImageStyle
        /// Print frontmatter as a line of chips (pinned, tags, other keys).
        public var showsProperties: Bool

        public init(
            resolveImage: @escaping (String) -> String? = { $0 },
            preview: @escaping (String) -> LinkCard? = { _ in nil },
            highlighter: SyntaxHighlighter? = nil,
            latex: LatexRenderer? = nil,
            theme: MarkdownEditorTheme = .default,
            bodyFontSize: CGFloat = 14,
            images: ImageStyle = .default,
            showsProperties: Bool = true
        ) {
            self.resolveImage = resolveImage
            self.preview = preview
            self.highlighter = highlighter
            self.latex = latex
            self.theme = theme
            self.bodyFontSize = bodyFontSize
            self.images = images
            self.showsProperties = showsProperties
        }
    }

    /// The document as an HTML body fragment.
    public static func body(for markdown: String, options: Options = Options()) -> String {
        Renderer(markdown, options: options).render()
    }

    /// `&`, `<`, `>`, `"` escaped.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf16.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }
}

// MARK: - Renderer

struct Renderer {
    let text: String
    let ns: NSString
    let options: MarkdownHTML.Options
    /// Formula values by the link's document range.
    let formulas: [NSRange: MarkdownFormulas.FormulaResult]

    init(_ text: String, options: MarkdownHTML.Options, formulas: [NSRange: MarkdownFormulas.FormulaResult]? = nil) {
        self.text = text
        self.ns = text as NSString
        self.options = options
        self.formulas = formulas ?? Dictionary(
            MarkdownFormulas.evaluate(document: text).map { ($0.range, $0) },
            uniquingKeysWith: { a, _ in a }
        )
    }

    func render() -> String {
        var html = ""
        for block in DocumentAST.parse(text) {
            html += render(block)
        }
        return html
    }

    private func source(_ range: NSRange) -> String { ns.substring(with: range) }

    /// A block's own trailing line break isn't a line of its own.
    static func trimmingBreaks(_ html: String) -> String {
        var html = html
        while html.hasSuffix("<br>") { html.removeLast(4) }
        return html
    }

    private func render(_ block: BlockNode) -> String {
        switch block {
        case .frontmatter(let range):
            return options.showsProperties ? properties(source(range)) : ""
        case .paragraph(let range, let inlines):
            let raw = source(range).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("<!--"), raw.hasSuffix("-->") { return "" }
            if let figure = blockFigure(inlines) { return figure }
            return "<p>\(Self.trimmingBreaks(inline(inlines)))</p>\n"
        case .heading(let level, _, _, let inlines):
            let l = min(max(level, 1), 6)
            return "<h\(l)>\(Self.trimmingBreaks(inline(inlines)))</h\(l)>\n"
        case .blockquote(let range, _):
            // Strip one `>` level and render the inside as a document of its own.
            let inner = source(range).components(separatedBy: "\n").map { line -> String in
                var s = Substring(line)
                while s.first == " " { s = s.dropFirst() }
                if s.first == ">" { s = s.dropFirst(); if s.first == " " { s = s.dropFirst() } }
                return String(s)
            }.joined(separator: "\n")
            return "<blockquote>\(Renderer(inner, options: options, formulas: [:]).render())</blockquote>\n"
        case .list(_, let items):
            return list(items)
        case .codeBlock(let range):
            return codeBlock(source(range))
        case .blockLatex(let range):
            var body = source(range).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("$$") { body.removeFirst(2) }
            if body.hasSuffix("$$") { body.removeLast(2) }
            return "<div class=\"nmw-math\">\(latex(body.trimmingCharacters(in: .whitespacesAndNewlines), block: true))</div>\n"
        case .table(let range):
            return table(range)
        case .thematicBreak:
            return "<hr>\n"
        case .blank:
            return ""
        }
    }

    // MARK: Frontmatter

    private func properties(_ block: String) -> String {
        var lines = block.components(separatedBy: .newlines)
        lines = lines.filter { $0.trimmingCharacters(in: .whitespaces) != "---" && $0.trimmingCharacters(in: .whitespaces) != "..." }
        var chips: [String] = []
        var currentKey: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if trimmed.hasPrefix("- "), currentKey == "tags" {
                chips.append(tagChip(String(trimmed.dropFirst(2))))
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            currentKey = key.lowercased()
            if currentKey == "tags" {
                if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
                for tag in value.split(separator: ",") { chips.append(tagChip(String(tag))) }
                continue
            }
            if currentKey == "pinned" {
                if value.lowercased() == "true" { chips.append("<span class=\"nmw-chip nmw-pin\">📌 Pinned</span>") }
                continue
            }
            guard !value.isEmpty else { continue }
            chips.append("<span class=\"nmw-chip\"><b>\(MarkdownHTML.escape(key))</b> \(MarkdownHTML.escape(unquoted(value)))</span>")
        }
        return chips.isEmpty ? "" : "<div class=\"nmw-properties\">\(chips.joined(separator: " "))</div>\n"
    }

    private func tagChip(_ raw: String) -> String {
        let tag = unquoted(raw.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return tag.isEmpty ? "" : "<span class=\"nmw-chip nmw-tag\">#\(MarkdownHTML.escape(tag))</span>"
    }

    private func unquoted(_ s: String) -> String {
        if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" { return String(s.dropFirst().dropLast()) }
        return s
    }

    // MARK: Lists

    private func list(_ items: [ListItem]) -> String {
        // Nest by indentation: a deeper item opens a list inside the previous item.
        var html = ""
        var stack: [(indent: Int, ordered: Bool)] = []
        var openItem = [Bool]()   // per level: an <li> is open
        func open(_ item: ListItem) {
            let tag = item.ordered ? "ol" : "ul"
            let start = item.ordered && (item.number ?? 1) != 1 ? " start=\"\(item.number ?? 1)\"" : ""
            let cls = item.checkbox != nil ? " class=\"nmw-tasks\"" : ""
            html += "<\(tag)\(start)\(cls)>"
            stack.append((item.indent, item.ordered))
            openItem.append(false)
        }
        func close() {
            if openItem.last == true { html += "</li>" }
            let level = stack.removeLast()
            openItem.removeLast()
            html += level.ordered ? "</ol>" : "</ul>"
        }
        for item in items {
            if stack.isEmpty { open(item) }
            while let top = stack.last, item.indent < top.indent, stack.count > 1 { close() }
            if let top = stack.last, item.indent > top.indent { open(item) }
            if openItem.last == true { html += "</li>" }
            openItem[openItem.count - 1] = true
            if item.checkbox != nil {
                let cls = item.checked ? "nmw-task nmw-done" : "nmw-task"
                let box = item.checked ? "☑" : "☐"
                html += "<li class=\"\(cls)\"><span class=\"nmw-box\">\(box)</span> <span class=\"nmw-task-text\">\(inline(item.inlines))</span>"
            } else {
                html += "<li>\(inline(item.inlines))"
            }
        }
        while !stack.isEmpty { close() }
        return html + "\n"
    }

    // MARK: Code

    private func codeBlock(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        var language: String?
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("```") || first.hasPrefix("~~~") {
            let info = first.dropFirst(3).trimmingCharacters(in: .whitespaces)
            language = info.isEmpty ? nil : String(info.split(separator: " ").first ?? "")
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if let last = lines.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("```") || last.hasPrefix("~~~") { lines.removeLast() }
        let code = lines.joined(separator: "\n")
        let body: String
        if let highlighted = options.highlighter?.highlight(code: code, language: language) {
            body = Self.spans(highlighted)
        } else {
            body = MarkdownHTML.escape(code)
        }
        let lang = language.map { " data-lang=\"\(MarkdownHTML.escape($0))\"" } ?? ""
        return "<pre class=\"nmw-code\"\(lang)><code>\(body)</code></pre>\n"
    }

    /// Foreground-colored runs as `<span style="color:…">`.
    static func spans(_ attributed: NSAttributedString) -> String {
        var html = ""
        attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let text = MarkdownHTML.escape((attributed.string as NSString).substring(with: range))
            if let color = value as? PlatformColor, let css = cssColor(color) {
                html += "<span style=\"color:\(css)\">\(text)</span>"
            } else {
                html += text
            }
        }
        return html
    }

    static func cssColor(_ color: PlatformColor) -> String? {
        #if os(macOS)
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let (r, g, b, a) = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
        #else
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #endif
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(r * 255), Int(g * 255), Int(b * 255), a)
    }

    // MARK: Tables

    private func table(_ range: NSRange) -> String {
        let raw = source(range).trimmingCharacters(in: .newlines)
        guard let table = MarkdownTable(source: raw) else {
            return "<pre>\(MarkdownHTML.escape(raw))</pre>\n"
        }
        // Formula values for this table, by (row, column); row 0 is the header.
        var values: [Int: [Int: MarkdownFormulas.FormulaResult]] = [:]
        for (r, result) in formulas where NSIntersectionRange(r, range).length > 0 || NSLocationInRange(r.location, range) {
            if let (row, column) = Self.cellPosition(result.cell) {
                values[row, default: [:]][column] = result
            }
        }
        var html = "<table class=\"nmw-table\">"
        if table.columnWidths.contains(where: { $0 != .auto }) {
            html += "<colgroup>"
            for c in 0..<table.columnCount {
                let width = c < table.columnWidths.count ? table.columnWidths[c] : .auto
                switch width {
                case .auto: html += "<col>"
                case .points(let p): html += "<col style=\"width:\(Int(p))px\">"
                case .percent(let p): html += "<col style=\"width:\(Self.number(Double(p)))%\">"
                }
            }
            html += "</colgroup>"
        }
        func cell(_ tag: String, _ row: Int, _ column: Int) -> String {
            let align: String = switch table.alignments[column] {
            case .left: " style=\"text-align:left\""
            case .center: " style=\"text-align:center\""
            case .right: " style=\"text-align:right\""
            case .none: ""
            }
            let content: String
            if let result = values[row]?[column], MarkdownFormulas.formula(inCell: table[row, column]) != nil {
                let cls = result.isError ? "nmw-formula nmw-error" : "nmw-formula"
                content = "<span class=\"\(cls)\" title=\"=\(MarkdownHTML.escape(result.formula))\">\(MarkdownHTML.escape(result.value))</span>"
            } else {
                content = inlineSource(table[row, column])
            }
            return "<\(tag)\(align)>\(content)</\(tag)>"
        }
        html += "<thead><tr>" + (0..<table.columnCount).map { cell("th", 0, $0) }.joined() + "</tr></thead><tbody>"
        for row in 1..<table.rowCount {
            html += "<tr>" + (0..<table.columnCount).map { cell("td", row, $0) }.joined() + "</tr>"
        }
        return html + "</tbody></table>\n"
    }

    /// "C3" → (row 3, column 2).
    static func cellPosition(_ address: String) -> (Int, Int)? {
        var column = 0
        var digits = ""
        for ch in address.uppercased() {
            if let ascii = ch.asciiValue, ch.isLetter, digits.isEmpty {
                column = column * 26 + Int(ascii - 64)
            } else if ch.isNumber {
                digits.append(ch)
            } else if ch != "$" {
                return nil
            }
        }
        guard column > 0, let row = Int(digits) else { return nil }
        return (row, column - 1)
    }

    static func cellPositionForTests(_ address: String) -> [Int]? { cellPosition(address).map { [$0.0, $0.1] } }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: Inline

    /// A paragraph that is only an image or a `{.preview}` link: a figure / card of its own.
    private func blockFigure(_ inlines: [InlineNode]) -> String? {
        let meaningful = inlines.filter { node in
            if case .text(let r) = node { return !source(r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
        guard meaningful.count == 1 else { return nil }
        switch meaningful[0] {
        case .image(_, let alt, let url, let markers):
            let attributes = self.attributes(markers)
            let img = image(alt: alt, url: url, attributes: attributes, inline: false)
            let align = attributes.alignment.map { " nmw-\($0.rawValue)" } ?? ""
            return "<figure class=\"nmw-figure\(align)\">\(img)</figure>\n"
        case .link(_, _, let url, let markers, let children):
            let attributes = self.attributes(markers)
            guard attributes.classes.contains("preview") else { return nil }
            let destination = source(url)
            let label = plain(children)
            guard let card = options.preview(destination) else { return nil }
            return self.card(card, destination: destination, label: label, attributes: attributes)
        default:
            return nil
        }
    }

    private func card(_ card: MarkdownHTML.LinkCard, destination: String, label: String, attributes: MarkdownAttributes) -> String {
        let align = attributes.alignment.map { " nmw-\($0.rawValue)" } ?? ""
        let size = attributes.size.map { " nmw-card-\($0.rawValue)" } ?? ""
        var html = "<div class=\"nmw-card\(size)\(align)\">"
        if let image = card.imageSource, attributes.size != .icon, attributes.size != .small {
            html += "<img class=\"nmw-card-image\" src=\"\(MarkdownHTML.escape(image))\">"
        }
        html += "<div class=\"nmw-card-text\">"
        if let icon = card.iconSource { html += "<img class=\"nmw-card-icon\" src=\"\(MarkdownHTML.escape(icon))\">" }
        html += "<div class=\"nmw-card-title\">\(MarkdownHTML.escape(card.title.isEmpty ? label : card.title))</div>"
        if let summary = card.summary, !summary.isEmpty, attributes.size != .icon {
            html += "<div class=\"nmw-card-summary\">\(MarkdownHTML.escape(summary))</div>"
        }
        html += "<div class=\"nmw-card-subtitle\">\(MarkdownHTML.escape(card.subtitle ?? destination))</div>"
        return html + "</div></div>\n"
    }

    /// The `{…}` block after a link or image (its fifth marker), if any.
    private func attributes(_ markers: [NSRange]) -> MarkdownAttributes {
        guard markers.count > 4 else { return MarkdownAttributes() }
        return MarkdownAttributes(source: source(markers[4])) ?? MarkdownAttributes()
    }

    private func image(alt: NSRange, url: NSRange, attributes: MarkdownAttributes, inline: Bool) -> String {
        let destination = source(url).trimmingCharacters(in: .whitespaces)
        let altText = MarkdownHTML.escape(source(alt))
        guard let src = options.resolveImage(destination) else {
            return "<span class=\"nmw-missing\">[\(altText.isEmpty ? MarkdownHTML.escape(destination) : altText)]</span>"
        }
        var style: [String] = []
        if let width = attributes.width { style.append("width:\(Int(width))px") }
        if let height = attributes.height { style.append("height:\(Int(height))px") }
        if attributes.width == nil, attributes.height == nil {
            switch attributes.size {
            case .icon: style.append("height:1.2em;vertical-align:-0.2em")
            case .small: style.append("max-width:min(100%,\(Int(options.images.smallWidth))px)")
            case .medium: style.append("max-width:min(100%,\(Int(options.images.mediumWidth))px)")
            case .large: style.append("max-width:min(100%,\(Int(options.images.largeWidth))px)")
            case .full: style.append("width:100%")
            case nil: break
            }
        }
        let cls = inline || attributes.size == .icon ? "nmw-inline-image" : "nmw-image"
        let styleAttr = style.isEmpty ? "" : " style=\"\(style.joined(separator: ";"))\""
        return "<img class=\"\(cls)\" src=\"\(MarkdownHTML.escape(src))\" alt=\"\(altText)\"\(styleAttr)>"
    }

    private func latex(_ formula: String, block: Bool) -> String {
        if let renderer = options.latex,
           let result = renderer.render(latex: formula, fontSize: options.bodyFontSize * (block ? 1.2 : 1), theme: options.theme),
           let data = Self.pngData(result.image) {
            let w = Int(result.size.width.rounded(.up)), h = Int(result.size.height.rounded(.up))
            let valign = block ? "" : String(format: ";vertical-align:-%.1fpx", result.baselineOffset)
            return "<img class=\"nmw-latex\" src=\"data:image/png;base64,\(data.base64EncodedString())\" style=\"width:\(w)px;height:\(h)px\(valign)\" alt=\"\(MarkdownHTML.escape(formula))\">"
        }
        return "<code class=\"nmw-latex-source\">\(MarkdownHTML.escape(formula))</code>"
    }

    static func pngData(_ image: PlatformImage) -> Data? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return image.pngData()
        #endif
    }

    /// Inline markdown from a table cell.
    private func inlineSource(_ cell: String) -> String {
        let renderer = Renderer(cell, options: options, formulas: [:])
        return renderer.inline(InlineParser.parse(cell))
    }

    private func plain(_ nodes: [InlineNode]) -> String {
        nodes.map { node -> String in
            switch node {
            case .text(let r): return source(r)
            case .code(_, let c): return source(c)
            case .emphasis(_, _, _, let children), .strikethrough(_, _, let children), .link(_, _, _, _, let children):
                return plain(children)
            case .image(_, let alt, _, _): return source(alt)
            case .inlineLatex(_, let c, _): return source(c)
            case .escape(_, let c, _): return source(c)
            }
        }.joined()
    }

    func inline(_ nodes: [InlineNode]) -> String {
        var html = ""
        for node in nodes {
            switch node {
            case .text(let r):
                html += text(source(r))
            case .code(_, let content):
                html += "<code>\(MarkdownHTML.escape(source(content)))</code>"
            case .emphasis(let kind, _, _, let children):
                let inner = inline(children)
                switch kind {
                case .italic: html += "<em>\(inner)</em>"
                case .bold: html += "<strong>\(inner)</strong>"
                case .boldItalic: html += "<strong><em>\(inner)</em></strong>"
                }
            case .strikethrough(_, _, let children):
                html += "<del>\(inline(children))</del>"
            case .link(let range, _, let url, let markers, let children):
                html += link(range: range, url: url, markers: markers, children: children)
            case .image(_, let alt, let url, let markers):
                html += image(alt: alt, url: url, attributes: attributes(markers), inline: true)
            case .inlineLatex(_, let content, _):
                html += latex(source(content), block: false)
            case .escape(_, let character, _):
                html += MarkdownHTML.escape(source(character))
            }
        }
        return html
    }

    private func link(range: NSRange, url: NSRange, markers: [NSRange], children: [InlineNode]) -> String {
        let destination = source(url).trimmingCharacters(in: .whitespaces)
        let label = inline(children)
        if let result = formulas[range] {
            let cls = result.isError ? "nmw-formula nmw-error" : "nmw-formula"
            return "<span class=\"\(cls)\">\(MarkdownHTML.escape(result.value))</span>"
        }
        let attributes = self.attributes(markers)
        if attributes.classes.contains("preview"), let card = options.preview(destination) {
            // Inline: the card's title as the link text.
            return "<a class=\"nmw-link\" href=\"\(MarkdownHTML.escape(Self.href(destination)))\">\(MarkdownHTML.escape(card.title.isEmpty ? plain(children) : card.title))</a>"
        }
        let href = Self.href(destination)
        guard Self.isWebLink(href) else { return "<span class=\"nmw-link\">\(label)</span>" }
        return "<a class=\"nmw-link\" href=\"\(MarkdownHTML.escape(href))\">\(label)</a>"
    }

    static func href(_ destination: String) -> String {
        destination.lowercased().hasPrefix("www.") ? "https://" + destination : destination
    }

    static func isWebLink(_ href: String) -> Bool {
        let lower = href.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
    }

    private static let bareURL = try! NSRegularExpression(pattern: #"\b(?:https?://|www\.)[^\s<>()]+[^\s<>().,;:!?'"]"#)
    private static let inlineTag = try! NSRegularExpression(pattern: #"(?<![\w/#])#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)"#)

    /// Plain text: escaped, line breaks kept (the editor shows them), bare URLs and `#tags` styled.
    private func text(_ raw: String) -> String {
        let ns = raw as NSString
        var html = ""
        var cursor = 0
        let matches = Self.bareURL.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            html += tagged(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            let url = ns.substring(with: m.range)
            html += "<a class=\"nmw-link\" href=\"\(MarkdownHTML.escape(Self.href(url)))\">\(MarkdownHTML.escape(url))</a>"
            cursor = NSMaxRange(m.range)
        }
        html += tagged(ns.substring(from: cursor))
        return html.replacingOccurrences(of: "\n", with: "<br>")
    }

    private func tagged(_ raw: String) -> String {
        let ns = raw as NSString
        var html = ""
        var cursor = 0
        for m in Self.inlineTag.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
            guard !tag.allSatisfy(\.isNumber) else { continue }
            html += MarkdownHTML.escape(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            html += "<span class=\"nmw-tag\">#\(MarkdownHTML.escape(tag))</span>"
            cursor = NSMaxRange(m.range)
        }
        return html + MarkdownHTML.escape(ns.substring(from: cursor))
    }
}
