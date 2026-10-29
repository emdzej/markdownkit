//
//  MarkdownStyler+Images.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Markdown image (`![alt](source)`) styling and layout.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

extension MarkdownStyler {

    // MARK: Markdown Image Links ![alt](url)

    /// Style `![alt](source){attrs}` by asking the embedder-supplied
    /// `ImageProvider` for `source`; if it returns `nil` the markdown source
    /// stays visible with dimmed markers. Standalone images render as blocks
    /// sized and aligned by their attributes; `.icon` images render inline,
    /// at line height, anywhere in a paragraph.
    static func styleImageLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .imageLink {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            // The URL lives between markerRanges[2] ('(') and markerRanges[3] (')');
            // markerRanges[4], when present, is the `{…}` attribute block.
            guard token.markerRanges.count >= 4 else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }
            let openParen = token.markerRanges[2]
            let closeParen = token.markerRanges[3]
            let urlStart = NSMaxRange(openParen)
            let urlLength = closeParen.location - urlStart
            guard urlLength > 0 else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }
            let urlRange = NSRange(location: urlStart, length: urlLength)
            let url = ctx.nsText.substring(with: urlRange)
            let attributes = token.markerRanges.count > 4
                ? MarkdownAttributes(source: ctx.nsText.substring(with: token.markerRanges[4])) ?? MarkdownAttributes()
                : MarkdownAttributes()
            let isActive = ctx.activeTokenIndices.contains(idx)

            let request = ImageRequest(source: url, attributes: attributes)
            guard let image = ctx.services.images.image(for: request) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }

            let imageConfig = ctx.configuration.images
            let maxWidth: CGFloat = {
                if let tc = ctx.layoutBridge?.firstTextContainer {
                    let w = tc.size.width - tc.lineFragmentPadding * 2
                    if w > 0 && w < imageConfig.unreasonableMaxWidth { return w }
                }
                return imageConfig.fallbackMaxWidth
            }()
            let lineHeight = ctx.baseFont.ascender - ctx.baseFont.descender
            let displaySize = imageConfig.displaySize(
                natural: image.size,
                attributes: attributes,
                widthHint: ImageStyle.widthHint(alt: ctx.nsText.substring(with: token.contentRange)),
                maxWidth: maxWidth,
                lineHeight: lineHeight
            )

            if attributes.size == .icon {
                if isActive {
                    appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                } else {
                    appendInlineImage(image, size: displaySize, for: token, ctx: ctx, attrs: &attrs)
                }
                continue
            }

            let imageBounds = CGRect(origin: .zero, size: displaySize)
            let leadingIndent: CGFloat = {
                let free = max(0, maxWidth - displaySize.width)
                switch attributes.alignment {
                case .center: return (free / 2).rounded(.down)
                case .right: return free
                case .left, nil: return 0
                }
            }()
            let rawContent = ctx.nsText.substring(with: token.range)
            let rendered: Bool
            if isActive {
                rendered = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawContent,
                    image: image,
                    imageBounds: imageBounds,
                    paragraphSpacingBefore: imageConfig.paragraphSpacing,
                    paragraphSpacing: imageConfig.paragraphSpacing,
                    alignment: .left,
                    mode: .visibleSource(imageGap: imageConfig.imageGap),
                    ctx: ctx,
                    attrs: &attrs
                )
            } else {
                rendered = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawContent,
                    image: image,
                    imageBounds: imageBounds,
                    paragraphSpacingBefore: imageConfig.paragraphSpacing,
                    paragraphSpacing: imageConfig.paragraphSpacing,
                    alignment: .left,
                    leadingIndent: leadingIndent,
                    mode: .collapsedSource(markerTexts: ["![", "]", "(", ")"]),
                    ctx: ctx,
                    attrs: &attrs
                )
                if rendered {
                    // The standalone helper hides the alt text + the
                    // markers, but the URL between '(' and ')' is its own
                    // range and stays visible unless we collapse it too.
                    let urlText = ctx.nsText.substring(with: urlRange)
                    attrs.append((urlRange, [
                        .foregroundColor: PlatformColor.clear,
                        .font: ctx.latexMarkerFont,
                        .kern: -HeadingHelpers.textWidth(urlText, font: ctx.latexMarkerFont)
                    ]))
                }
            }
            if !rendered {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }

    /// Draws `image` in the text flow, sitting on the baseline like a glyph:
    /// the token's first character carries the image and its advance, the
    /// rest of the source collapses.
    private static func appendInlineImage(
        _ image: PlatformImage, size: CGSize, for token: MarkdownToken,
        ctx: StylingContext, attrs: inout [StyledRange]
    ) {
        let anchor = NSRange(location: token.range.location, length: 1)
        let anchorText = ctx.nsText.substring(with: anchor)
        attrs.append((anchor, [
            .latexImage: image,
            // Positive y = how far the image reaches below the baseline.
            .latexBounds: NSValue(mdRect: CGRect(x: 0, y: -ctx.baseFont.descender, width: size.width, height: size.height)),
            .foregroundColor: PlatformColor.clear,
            .font: ctx.latexMarkerFont,
            .kern: size.width - HeadingHelpers.textWidth(anchorText, font: ctx.latexMarkerFont)
        ]))
        let rest = NSRange(location: anchor.location + 1, length: token.range.length - 1)
        guard rest.length > 0 else { return }
        attrs.append((rest, [
            .foregroundColor: PlatformColor.clear,
            .font: ctx.latexMarkerFont,
            .kern: -ctx.latexMarkerFont.pointSize
        ]))
    }

}
