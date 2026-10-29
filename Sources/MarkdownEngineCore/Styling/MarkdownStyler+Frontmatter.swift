//
//  MarkdownStyler+Frontmatter.swift
//  MarkdownEngine
//
//  YAML frontmatter opening a note (`---` … `---`). In formatted mode it
//  collapses to one line of chips — a pin for `pinned: true`, `#tag`s, and
//  `key: value` pills — while the caret is elsewhere; the caret inside (or a
//  click on the chips) shows the raw lines, colored like source mode.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

/// The top-level `key: value` pairs of a frontmatter block. Not a YAML
/// parser: scalars, inline lists (`[a, b]`) and block lists (`- a`) only;
/// nested maps show as their raw first line.
struct FrontmatterProperties: Equatable {
    enum Value: Equatable {
        case scalar(String)
        case list([String])
    }

    struct Property: Equatable {
        let key: String
        let value: Value
    }

    let properties: [Property]

    init(_ content: String) {
        var properties: [Property] = []
        var pendingKey: String?
        var pendingItems: [String] = []

        func flush() {
            if let key = pendingKey { properties.append(Property(key: key, value: pendingItems.isEmpty ? .scalar("") : .list(pendingItems))) }
            pendingKey = nil
            pendingItems = []
        }

        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let indented = raw.first == " " || raw.first == "\t"
            if line.hasPrefix("- "), pendingKey != nil {
                pendingItems.append(Self.unquote(String(line.dropFirst(2))))
                continue
            }
            if indented, pendingKey != nil { continue }   // nested map: keep the key, skip its body
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = Self.unquote(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if value.isEmpty {
                pendingKey = key
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                let items = value.dropFirst().dropLast().split(separator: ",")
                    .map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                properties.append(Property(key: key, value: .list(items)))
            } else {
                properties.append(Property(key: key, value: .scalar(Self.unquote(value))))
            }
        }
        flush()
        self.properties = properties
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, first == s.last, first == "\"" || first == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// What the collapsed line shows, in order: the pin, tags, then the rest.
    enum Chip: Equatable {
        case pinned
        case tag(String)
        case property(key: String, value: String)
        /// No properties at all.
        case empty
    }

    var chips: [Chip] {
        var pinned = false
        var tags: [Chip] = []
        var others: [Chip] = []
        for property in properties {
            let key = property.key.lowercased()
            switch (key, property.value) {
            case ("pinned", .scalar(let v)) where v.lowercased() == "true":
                pinned = true
            case ("tags", .list(let items)), ("tag", .list(let items)):
                tags += items.map { .tag($0.hasPrefix("#") ? String($0.dropFirst()) : $0) }
            case ("tags", .scalar(let v)), ("tag", .scalar(let v)):
                tags += v.split(whereSeparator: { $0 == "," || $0 == " " })
                    .map { .tag($0.hasPrefix("#") ? String($0.dropFirst()) : String($0)) }
            case (_, .scalar(let v)):
                others.append(.property(key: property.key, value: v))
            case (_, .list(let items)):
                others.append(.property(key: property.key, value: items.joined(separator: ", ")))
            }
        }
        let chips = (pinned ? [Chip.pinned] : []) + tags + others
        return chips.isEmpty ? [.empty] : chips
    }
}

extension MarkdownStyler {

    static func styleFrontmatter(_ ctx: StylingContext) -> [StyledRange] {
        guard let (idx, token) = ctx.tokens.enumerated().first(where: { $0.element.kind == .frontmatter }) else { return [] }
        var attrs: [StyledRange] = [(token.range, [.spellingState: 0])]
        if ctx.activeTokenIndices.contains(idx) {
            attrs += frontmatterSourceAttributes(token, ns: ctx.nsText, theme: ctx.configuration.theme, source: ctx.configuration.source)
            return attrs
        }

        let content = ctx.nsText.substring(with: token.contentRange)
        let chips = FrontmatterProperties(content).chips
        let image = renderFrontmatterChips(
            chips,
            maxWidth: effectiveContainerWidth(for: ctx),
            baseFont: ctx.baseFont,
            theme: ctx.configuration.theme,
            appearance: tableRenderAppearance(ctx)
        )
        // The image sits on the first non-blank content character; with no
        // content it sits on the opening fence instead.
        let renderToken = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? MarkdownToken(kind: .frontmatter, range: token.range,
                            contentRange: NSRange(location: token.range.location, length: NSMaxRange(token.markerRanges[1]) - token.range.location),
                            markerRanges: [])
            : token
        _ = appendRenderedStandaloneBlock(
            for: renderToken,
            rawContent: ctx.nsText.substring(with: renderToken.contentRange),
            image: image,
            imageBounds: CGRect(origin: .zero, size: image.size),
            paragraphSpacingBefore: 0,
            paragraphSpacing: ctx.configuration.linkPreviews.paragraphSpacing,
            alignment: .left,
            mode: .collapsedSource(markerTexts: []),
            ctx: ctx,
            attrs: &attrs
        )
        return attrs
    }

    /// Raw frontmatter colored for editing: muted fences, `-` and `:`, keys in the key color.
    static func frontmatterSourceAttributes(
        _ token: MarkdownToken, ns: NSString, theme: MarkdownEditorTheme, source: SourceModeStyle
    ) -> [StyledRange] {
        var attrs: [StyledRange] = token.markerRanges.map { ($0, [.foregroundColor: theme.mutedText]) }
        var cursor = token.contentRange.location
        let end = NSMaxRange(token.contentRange)
        while cursor < end {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            defer { cursor = max(NSMaxRange(line), cursor + 1) }
            let text = ns.substring(with: line) as NSString
            var i = 0
            while i < text.length, text.character(at: i) == 0x20 || text.character(at: i) == 0x09 { i += 1 }
            if i < text.length, text.character(at: i) == 0x23 {   // # comment
                attrs.append((NSRange(location: line.location + i, length: text.length - i), [.foregroundColor: theme.mutedText]))
                continue
            }
            if i + 1 < text.length, text.character(at: i) == 0x2D, text.character(at: i + 1) == 0x20 {   // "- "
                attrs.append((NSRange(location: line.location + i, length: 1), [.foregroundColor: theme.mutedText]))
                continue
            }
            let colon = text.range(of: ":")
            guard colon.location != NSNotFound, colon.location > i else { continue }
            attrs.append((NSRange(location: line.location + i, length: colon.location - i), [.foregroundColor: source.keyColor]))
            attrs.append((NSRange(location: line.location + colon.location, length: 1), [.foregroundColor: theme.mutedText]))
        }
        return attrs
    }

    /// The collapsed frontmatter: chips wrapped into rows no wider than `maxWidth`.
    static func renderFrontmatterChips(
        _ chips: [FrontmatterProperties.Chip],
        maxWidth: CGFloat,
        baseFont: PlatformFont,
        theme: MarkdownEditorTheme,
        appearance: PlatformAppearance
    ) -> PlatformImage {
        let font = baseFont.withSize((baseFont.pointSize * 0.78).rounded())
        let boldFont = PlatformFont.md(descriptor: font.fontDescriptor, traits: .bold, size: font.pointSize) ?? font
        let body = theme.bodyText.mdResolved(in: appearance)
        let muted = theme.mutedText.mdResolved(in: appearance)
        let link = (theme.tagChip ?? theme.link).mdResolved(in: appearance)
        let chipFill = theme.chipBackground?.mdResolved(in: appearance) ?? muted.withAlphaComponent(0.12)
        let pin = PlatformColor.systemOrange.mdResolved(in: appearance)

        let padX: CGFloat = 8, padY: CGFloat = 3, gap: CGFloat = 6
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        let chipHeight = textHeight + padY * 2
        let iconSide = ceil(font.capHeight + 3)
        let maxText: Int = 40

        func clipped(_ s: String) -> String { s.count > maxText ? String(s.prefix(maxText - 1)) + "…" : s }

        struct Laid {
            let label: NSAttributedString
            let icon: PlatformImage?
            let fill: PlatformColor
            var rect: CGRect
        }

        var laid: [Laid] = []
        for chip in chips {
            let label = NSMutableAttributedString()
            var icon: PlatformImage?
            var fill = chipFill
            switch chip {
            case .pinned:
                icon = PlatformImage.mdSymbol("pin.fill")?.mdApplying(.init(paletteColors: [pin]))
                label.append(NSAttributedString(string: "Pinned", attributes: [.font: font, .foregroundColor: body]))
            case .tag(let tag):
                label.append(NSAttributedString(string: "#" + clipped(tag), attributes: [.font: font, .foregroundColor: link]))
                fill = link.withAlphaComponent(0.12)
            case .property(let key, let value):
                label.append(NSAttributedString(string: clipped(key), attributes: [.font: boldFont, .foregroundColor: muted]))
                if !value.isEmpty {
                    label.append(NSAttributedString(string: "  " + clipped(value), attributes: [.font: font, .foregroundColor: body]))
                }
            case .empty:
                label.append(NSAttributedString(string: "Properties", attributes: [.font: font, .foregroundColor: muted]))
            }
            let iconWidth = icon.map { iconSide * $0.size.width / max($0.size.height, 1) + 4 } ?? 0
            let width = min(ceil(label.size().width) + iconWidth + padX * 2, max(maxWidth, 40))
            laid.append(Laid(label: label, icon: icon, fill: fill, rect: CGRect(x: 0, y: 0, width: width, height: chipHeight)))
        }

        // Flow layout.
        var x: CGFloat = 0, y: CGFloat = 0, usedWidth: CGFloat = 0
        for i in laid.indices {
            if x > 0, x + laid[i].rect.width > maxWidth {
                x = 0
                y += chipHeight + gap
            }
            laid[i].rect.origin = CGPoint(x: x, y: y)
            x += laid[i].rect.width + gap
            usedWidth = max(usedWidth, laid[i].rect.maxX)
        }
        let size = CGSize(width: max(1, ceil(usedWidth)), height: y + chipHeight)

        return PlatformImage.mdDrawing(size: size) {
            for chip in laid {
                let pill = PlatformBezierPath(roundedRect: chip.rect, xRadius: chipHeight / 2, yRadius: chipHeight / 2)
                chip.fill.setFill()
                pill.fill()
                var textX = chip.rect.minX + padX
                if let icon = chip.icon {
                    let w = iconSide * icon.size.width / max(icon.size.height, 1)
                    icon.mdDraw(aspectFitting: CGRect(x: textX, y: chip.rect.midY - iconSide / 2, width: w, height: iconSide))
                    textX += w + 4
                }
                chip.label.draw(with: CGRect(x: textX, y: chip.rect.minY + padY, width: chip.rect.maxX - padX - textX, height: textHeight),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            }
        }
    }
}
