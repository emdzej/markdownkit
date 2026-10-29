//
//  MarkdownStyler+LinkPreviews.swift
//  MarkdownEngine
//
//  `[text](destination){.preview}` styling. A link on its own line renders
//  as a card (raw source shown above it while the caret is on the link);
//  `.icon` puts the target's icon before the link text; an unavailable
//  target gets a muted badge. Everything else stays an ordinary link.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

extension MarkdownStyler {

    static func styleLinkPreviews(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let tableRanges = ctx.tokens.filter { $0.kind == .table }.map(\.range)
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .link && token.markerRanges.count > 4 {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            if tableRanges.contains(where: { NSLocationInRange(token.range.location, $0) }) { continue }
            guard let attributes = MarkdownAttributes(source: ctx.nsText.substring(with: token.markerRanges[4])),
                  attributes.wantsPreview else { continue }

            let openParen = token.markerRanges[2]
            let closeParen = token.markerRanges[3]
            let urlRange = NSRange(location: NSMaxRange(openParen), length: closeParen.location - NSMaxRange(openParen))
            guard urlRange.length > 0 else { continue }
            let request = LinkPreviewRequest(
                destination: ctx.nsText.substring(with: urlRange),
                text: ctx.nsText.substring(with: token.contentRange),
                attributes: attributes
            )
            guard let preview = ctx.services.linkPreviews.preview(for: request) else { continue }
            let isActive = ctx.activeTokenIndices.contains(idx)
            let appearance = tableRenderAppearance(ctx)

            if preview.status == .unavailable {
                if !isActive {
                    let badge = renderUnavailableBadge(baseFont: ctx.baseFont, theme: ctx.configuration.theme, appearance: appearance)
                    // Space the badge off the link text via the hidden `)`.
                    attrs.append((token.markerRanges[3], [.kern: 4]))
                    appendInlinePicture(badge, size: badge.size, gap: 4, at: token.markerRanges[4].location, ctx: ctx, attrs: &attrs)
                }
                continue
            }

            if attributes.size == .icon {
                if !isActive {
                    let icon = preview.icon ?? PlatformImage.mdSymbol("link")
                    if let icon, icon.size.height > 0 {
                        let side = ctx.baseFont.ascender - ctx.baseFont.descender
                        let size = CGSize(width: side * icon.size.width / icon.size.height, height: side)
                        appendInlinePicture(icon, size: size, gap: 3, at: token.markerRanges[0].location, ctx: ctx, attrs: &attrs)
                    }
                }
                continue
            }

            let style = ctx.configuration.linkPreviews
            let maxWidth = effectiveContainerWidth(for: ctx)
            let width = style.cardWidth(for: attributes, maxWidth: maxWidth)
            let card = renderLinkCard(
                LinkCardContent(preview, request: request),
                size: attributes.size ?? .medium,
                width: width,
                heroHeight: attributes.height,
                style: style,
                baseFont: ctx.baseFont,
                theme: ctx.configuration.theme,
                appearance: appearance
            )
            let bounds = CGRect(origin: .zero, size: card.size)
            let leadingIndent: CGFloat = {
                let free = max(0, maxWidth - card.size.width)
                switch attributes.alignment {
                case .center: return (free / 2).rounded(.down)
                case .right: return free
                case .left, nil: return 0
                }
            }()
            let rawContent = ctx.nsText.substring(with: token.range)
            if isActive {
                _ = appendRenderedStandaloneBlock(
                    for: token, rawContent: rawContent, image: card, imageBounds: bounds,
                    paragraphSpacingBefore: style.paragraphSpacing, paragraphSpacing: style.paragraphSpacing,
                    alignment: .left,
                    mode: .visibleSource(imageGap: ctx.configuration.images.imageGap),
                    ctx: ctx, attrs: &attrs
                )
            } else if appendRenderedStandaloneBlock(
                for: token, rawContent: rawContent, image: card, imageBounds: bounds,
                paragraphSpacingBefore: style.paragraphSpacing, paragraphSpacing: style.paragraphSpacing,
                alignment: .left, leadingIndent: leadingIndent,
                mode: .collapsedSource(markerTexts: ["[", "]", "(", ")"]),
                ctx: ctx, attrs: &attrs
            ) {
                // The helper hides text and markers; the destination is its own run.
                attrs.append((urlRange, [
                    .foregroundColor: PlatformColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: -HeadingHelpers.textWidth(ctx.nsText.substring(with: urlRange), font: ctx.latexMarkerFont)
                ]))
                // Clicking the card opens the link: the anchor keeps `.link`
                // from the link styling, and the card's line is all anchor.
            }
        }
        return attrs
    }

    /// Draws `image` inline on the (hidden) character at `location`, followed by `gap`.
    private static func appendInlinePicture(
        _ image: PlatformImage, size: CGSize, gap: CGFloat, at location: Int,
        ctx: StylingContext, attrs: inout [StyledRange]
    ) {
        let anchor = NSRange(location: location, length: 1)
        let font = ctx.latexMarkerFont
        // Centre on the text's x-height band; positive y reaches below the baseline.
        let below = max(0, (size.height - ctx.baseFont.capHeight) / 2)
        attrs.append((anchor, [
            .latexImage: image,
            .latexBounds: NSValue(mdRect: CGRect(x: 0, y: below, width: size.width, height: size.height)),
            .foregroundColor: PlatformColor.clear,
            .font: font,
            .kern: size.width + gap - HeadingHelpers.textWidth(ctx.nsText.substring(with: anchor), font: font)
        ]))
    }
}
