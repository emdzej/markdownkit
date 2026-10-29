//
//  LinkPreviewCard.swift
//  MarkdownEngine
//
//  Draws link preview cards (spec: `.small` one line, `.medium` thumbnail +
//  text, `.large` / `.full` hero image on top) and the inline pieces used
//  by `.icon` links and unavailable targets.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

/// Sizing for link preview cards.
public struct LinkPreviewStyle: Sendable {
    /// Card widths for `.small`, `.medium` (the `.preview` default) and `.large`;
    /// `.full` uses the column width. Cards never exceed the column.
    public var smallWidth: CGFloat
    public var mediumWidth: CGFloat
    public var largeWidth: CGFloat
    /// Height of the `.medium` card (its thumbnail is square, inset by `padding`).
    public var mediumHeight: CGFloat
    public var padding: CGFloat
    public var cornerRadius: CGFloat
    /// Vertical space above and below a card paragraph.
    public var paragraphSpacing: CGFloat

    public init(
        smallWidth: CGFloat = 360,
        mediumWidth: CGFloat = 480,
        largeWidth: CGFloat = 640,
        mediumHeight: CGFloat = 96,
        padding: CGFloat = 10,
        cornerRadius: CGFloat = 8,
        paragraphSpacing: CGFloat = 8
    ) {
        self.smallWidth = smallWidth
        self.mediumWidth = mediumWidth
        self.largeWidth = largeWidth
        self.mediumHeight = mediumHeight
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.paragraphSpacing = paragraphSpacing
    }

    public static let `default` = LinkPreviewStyle()

    /// Card width for `attributes` in a column `maxWidth` wide.
    public func cardWidth(for attributes: MarkdownAttributes, maxWidth: CGFloat) -> CGFloat {
        let width: CGFloat
        if let explicit = attributes.width {
            width = explicit
        } else {
            switch attributes.size {
            case .small: width = smallWidth
            case .large: width = largeWidth
            case .full: width = maxWidth
            case .medium, .icon, nil: width = mediumWidth
            }
        }
        return max(1, min(width, maxWidth))
    }
}

/// Text and pictures a card shows, with fallbacks for loading previews.
struct LinkCardContent {
    let title: String
    let summary: String?
    let subtitle: String?
    let icon: PlatformImage?
    let image: PlatformImage?

    init(_ preview: LinkPreview, request: LinkPreviewRequest) {
        let text = request.text.trimmingCharacters(in: .whitespaces)
        title = preview.title.flatMap { $0.isEmpty ? nil : $0 } ?? (text.isEmpty ? request.destination : text)
        summary = preview.status == .loading ? nil : preview.summary
        subtitle = preview.subtitle ?? Self.shortDestination(request.destination)
        icon = preview.icon
        image = preview.image
    }

    /// `https://www.swift.org/blog/x` → `swift.org`; paths keep their file name.
    static func shortDestination(_ destination: String) -> String {
        if let url = URL(string: destination), let host = url.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        let decoded = destination.removingPercentEncoding ?? destination
        return (decoded as NSString).lastPathComponent
    }
}

extension MarkdownStyler {

    static func renderLinkCard(
        _ content: LinkCardContent,
        size: MarkdownAttributes.Size,
        width: CGFloat,
        heroHeight: CGFloat?,
        style: LinkPreviewStyle,
        baseFont: PlatformFont,
        theme: MarkdownEditorTheme,
        appearance: PlatformAppearance
    ) -> PlatformImage {
        let p = style.padding
        let body = theme.bodyText.mdResolved(in: appearance)
        let muted = theme.mutedText.mdResolved(in: appearance)
        let titleFont = PlatformFont.md(descriptor: baseFont.fontDescriptor, traits: .bold, size: baseFont.pointSize) ?? baseFont
        let summaryFont = baseFont.withSize(baseFont.pointSize * 0.9)
        let subtitleFont = baseFont.withSize(baseFont.pointSize * 0.8)

        func text(_ string: String, _ font: PlatformFont, _ color: PlatformColor) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            // Wrap so heights measure every line; drawing truncates the last visible one.
            paragraph.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        func lineHeight(_ font: PlatformFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }
        /// Height of `string` wrapped to `width`, capped at `lines`.
        func height(_ string: NSAttributedString, width: CGFloat, lines: Int, font: PlatformFont) -> CGFloat {
            let full = string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin], context: nil).height
            return min(ceil(full), lineHeight(font) * CGFloat(lines))
        }

        let title = text(content.title, titleFont, body)
        let summary = content.summary.map { text($0, summaryFont, muted) }
        let subtitle = content.subtitle.map { text($0, subtitleFont, muted) }
        let iconSide = lineHeight(subtitleFont)

        // Layout: compute the card height and each piece's rect.
        var cardHeight: CGFloat
        var imageRect: CGRect?
        var iconRect: CGRect?
        var titleRect: CGRect
        var summaryRect: CGRect?
        var subtitleRect: CGRect?

        switch size {
        case .small, .icon:
            let lh = max(lineHeight(titleFont), iconSide)
            cardHeight = lh + 2 * p
            var x = p
            if content.icon != nil {
                iconRect = CGRect(x: x, y: (cardHeight - iconSide) / 2, width: iconSide, height: iconSide)
                x += iconSide + 6
            }
            var titleWidth = width - x - p
            if let subtitle {
                let w = min(ceil(subtitle.size().width), titleWidth * 0.4)
                subtitleRect = CGRect(x: width - p - w, y: (cardHeight - lineHeight(subtitleFont)) / 2,
                                      width: w, height: lineHeight(subtitleFont))
                titleWidth -= w + 8
            }
            titleRect = CGRect(x: x, y: (cardHeight - lineHeight(titleFont)) / 2, width: max(0, titleWidth), height: lineHeight(titleFont))

        case .medium:
            cardHeight = style.mediumHeight
            var x = p
            if content.image != nil {
                let side = cardHeight - 2 * p
                imageRect = CGRect(x: p, y: p, width: side, height: side)
                x += side + p
            }
            let textWidth = max(0, width - x - p)
            var y = p
            if subtitle != nil {
                if content.icon != nil {
                    iconRect = CGRect(x: x, y: y, width: iconSide, height: iconSide)
                }
                let sx = x + (content.icon != nil ? iconSide + 4 : 0)
                subtitleRect = CGRect(x: sx, y: y, width: max(0, x + textWidth - sx), height: lineHeight(subtitleFont))
                y += lineHeight(subtitleFont) + 2
            }
            let remaining = cardHeight - p - y
            let titleLines = summary == nil ? 3 : 2
            let th = min(height(title, width: textWidth, lines: titleLines, font: titleFont), remaining)
            titleRect = CGRect(x: x, y: y, width: textWidth, height: th)
            y += th + 2
            if let summary, cardHeight - p - y >= lineHeight(summaryFont) {
                let lines = Int((cardHeight - p - y) / lineHeight(summaryFont))
                summaryRect = CGRect(x: x, y: y, width: textWidth, height: height(summary, width: textWidth, lines: lines, font: summaryFont))
            }

        case .large, .full:
            var y: CGFloat = 0
            if let image = content.image, image.size.width > 0 {
                let natural = width * image.size.height / image.size.width
                let h = heroHeight ?? min(natural, width * 0.6)
                imageRect = CGRect(x: 0, y: 0, width: width, height: h)
                y = h
            }
            y += p
            let textWidth = max(0, width - 2 * p)
            if subtitle != nil {
                if content.icon != nil { iconRect = CGRect(x: p, y: y, width: iconSide, height: iconSide) }
                let sx = p + (content.icon != nil ? iconSide + 4 : 0)
                subtitleRect = CGRect(x: sx, y: y, width: max(0, width - p - sx), height: lineHeight(subtitleFont))
                y += lineHeight(subtitleFont) + 2
            }
            let th = height(title, width: textWidth, lines: 2, font: titleFont)
            titleRect = CGRect(x: p, y: y, width: textWidth, height: th)
            y += th
            if let summary {
                y += 2
                let sh = height(summary, width: textWidth, lines: 3, font: summaryFont)
                summaryRect = CGRect(x: p, y: y, width: textWidth, height: sh)
                y += sh
            }
            cardHeight = y + p
        }

        let cardSize = CGSize(width: width, height: ceil(cardHeight))
        let radius = style.cornerRadius
        let fill = muted.withAlphaComponent(0.06)
        let border = muted.withAlphaComponent(0.35)

        return PlatformImage.mdDrawing(size: cardSize) {
            let outline = PlatformBezierPath(roundedRect: CGRect(origin: .zero, size: cardSize).insetBy(dx: 0.5, dy: 0.5),
                                             xRadius: radius, yRadius: radius)
            fill.setFill()
            outline.fill()
            if let imageRect, let image = content.image {
                // The hero image fills the top of the card; clip to its rounded corners.
                let clip = size == .large || size == .full
                    ? outline
                    : PlatformBezierPath(roundedRect: imageRect, xRadius: radius / 2, yRadius: radius / 2)
                mdClipped(to: clip) {
                    image.mdDraw(aspectFilling: imageRect)
                }
            }
            if let iconRect, let icon = content.icon {
                icon.mdDraw(aspectFitting: iconRect)
            }
            title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            if let summaryRect, let summary { summary.draw(with: summaryRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil) }
            if let subtitleRect, let subtitle { subtitle.draw(with: subtitleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil) }
            border.setStroke()
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    /// A muted rounded "unavailable" badge, sized for the text line.
    static func renderUnavailableBadge(baseFont: PlatformFont, theme: MarkdownEditorTheme, appearance: PlatformAppearance) -> PlatformImage {
        let muted = theme.mutedText.mdResolved(in: appearance)
        let font = baseFont.withSize(baseFont.pointSize * 0.75)
        let label = NSAttributedString(string: "unavailable", attributes: [.font: font, .foregroundColor: muted])
        let textSize = label.size()
        let size = CGSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 4)
        return PlatformImage.mdDrawing(size: size) {
            let pill = PlatformBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                                          xRadius: size.height / 2, yRadius: size.height / 2)
            muted.withAlphaComponent(0.12).setFill()
            pill.fill()
            label.draw(at: CGPoint(x: 6, y: 2))
        }
    }

    private static func mdClipped(to path: PlatformBezierPath, _ draw: () -> Void) {
        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        #else
        UIGraphicsGetCurrentContext()?.saveGState()
        path.addClip()
        draw()
        UIGraphicsGetCurrentContext()?.restoreGState()
        #endif
    }
}

#if os(iOS) || os(visionOS)
extension UIBezierPath {
    /// AppKit spelling, so card drawing is shared.
    convenience init(roundedRect rect: CGRect, xRadius: CGFloat, yRadius: CGFloat) {
        self.init(roundedRect: rect, cornerRadius: xRadius)
    }
}
#endif

extension PlatformImage {
    /// Draws upright in the (flipped) card context, scaled to cover `rect`.
    func mdDraw(aspectFilling rect: CGRect) {
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        mdDrawUpright(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                 width: drawn.width, height: drawn.height))
    }

    /// Draws upright, scaled to fit inside `rect`.
    func mdDraw(aspectFitting rect: CGRect) {
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        mdDrawUpright(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                 width: drawn.width, height: drawn.height))
    }

    private func mdDrawUpright(in rect: CGRect) {
        #if os(macOS)
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        #else
        draw(in: rect)
        #endif
    }
}
