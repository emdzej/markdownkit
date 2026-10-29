//
//  MarkdownEditorServices.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Protocols and default implementations for engine-side dependencies.
//
//  The Markdown editor engine resolves images, syntax highlighting,
//  and LaTeX rendering through these protocols.
//  Embedders supply the concrete implementations; the engine never
//  reaches into the host app for any of these concerns.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

// MARK: - Images

/// Loads the image for a markdown image `![alt](source)`.
///
/// The engine hands the provider the raw `source` exactly as written (a
/// relative path, file URL, or remote URL). The provider decides
/// where the image actually lives (filesystem, remote, asset catalog).
public protocol ImageProvider: Sendable {
    /// Returns an image for the given reference, or `nil` if no image
    /// is available.
    func image(for request: ImageRequest) -> PlatformImage?

    /// A coarse fingerprint of the provider's current state. Returning
    /// a different value invalidates the engine's image cache. Embedders
    /// typically combine the IDs of all known images.
    func fingerprint() -> AnyHashable
}

/// What the engine asks an `ImageProvider` for.
public struct ImageRequest: Sendable, Equatable {
    /// The `source` of `![alt](source)`, verbatim.
    public let source: String
    /// The `{…}` attributes after the image (size, alignment, …), so a
    /// provider can pick a thumbnail of a suitable resolution.
    public let attributes: MarkdownAttributes

    public init(source: String, attributes: MarkdownAttributes = MarkdownAttributes()) {
        self.source = source
        self.attributes = attributes
    }
}

/// Default provider that never returns images.
public struct NoOpImageProvider: ImageProvider {
    public init() {}
    public func image(for request: ImageRequest) -> PlatformImage? { nil }
    public func fingerprint() -> AnyHashable { 0 }
}

// MARK: - Syntax Highlighting

/// Provides code-block font, background color, and syntax highlighting.
public protocol SyntaxHighlighter: Sendable {
    /// Monospace font used for fenced code blocks at the requested size.
    func codeFont(size: CGFloat) -> PlatformFont

    /// Background color used to fill code-block paragraphs. The engine
    /// also uses this color to detect which fragments are code blocks
    /// when drawing custom backgrounds.
    func backgroundColor() -> PlatformColor

    /// Highlight `code` written in `language`. Return an attributed string
    /// whose attributes carry per-token foreground colors. Return `nil` if
    /// no highlighting is available for this language.
    func highlight(code: String, language: String?) -> NSAttributedString?

    /// Notification name posted when the highlighter's appearance source
    /// changes (light/dark mode flip, theme switch). The engine subscribes
    /// to this notification so it can invalidate cached attributes.
    /// Return `nil` if the highlighter never changes after construction.
    var appearanceDidChangeNotification: Notification.Name? { get }
}

/// Default highlighter that produces no highlighting and supplies a
/// basic system monospace font on a transparent background.
public struct PlainTextSyntaxHighlighter: SyntaxHighlighter {
    public init() {}

    public func codeFont(size: CGFloat) -> PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public func backgroundColor() -> PlatformColor {
        PlatformColor.mdTextBackground.withAlphaComponent(0)
    }

    public func highlight(code: String, language: String?) -> NSAttributedString? {
        nil
    }

    public var appearanceDidChangeNotification: Notification.Name? { nil }
}

// MARK: - LaTeX

/// Renders LaTeX formulas to images for inline display.
public protocol LatexRenderer: Sendable {
    /// Render `latex` at the requested font size, optionally tinted by `theme`.
    /// - Returns: A rendered result, or `nil` if the renderer cannot produce
    ///   an image (unsupported syntax, missing dependency, …).
    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult?
}

/// Output of a LaTeX render call.
public struct LatexRenderResult: Sendable {
    public let image: PlatformImage
    public let size: CGSize
    /// Distance from the image's bottom edge to its visual baseline.
    /// Used to align inline math with the surrounding text.
    public let baselineOffset: CGFloat

    public init(image: PlatformImage, size: CGSize, baselineOffset: CGFloat) {
        self.image = image
        self.size = size
        self.baselineOffset = baselineOffset
    }
}

/// Default renderer that ignores LaTeX entirely. The engine falls back to
/// rendering the source text when this is in use.
public struct NoOpLatexRenderer: LatexRenderer {
    public init() {}
    public func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? { nil }
}

// MARK: - Event Bus

/// Optional notification-name bridge that lets the editor communicate with
/// surrounding UI without hard-coding any names of its own.
///
/// The engine observes the request notifications it is configured with and
/// posts the response notifications when supplied. Embedders that don't
/// need cross-view formatting commands simply leave every name `nil`.
public struct MarkdownEditorBus: Sendable {
    /// Posted by the host UI to request the engine apply bold styling.
    public var applyBoldRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply italic styling.
    public var applyItalicRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply a heading level.
    /// Expected `userInfo["level"] as? Int`.
    public var applyHeadingRequest: Notification.Name?
    /// Posted by the engine after every selection change with `userInfo["isBold"] as? Bool`.
    public var selectionBoldDidChange: Notification.Name?
    /// Posted by the engine after every selection change with `userInfo["isItalic"] as? Bool`.
    public var selectionItalicDidChange: Notification.Name?
    /// Posted by the host UI to scroll an in-document find match into view
    /// and highlight all matches. Expected `userInfo["range"] as? NSRange`,
    /// `userInfo["currentIndex"] as? Int`, `userInfo["allRanges"] as? [NSRange]`.
    public var findScrollToRange: Notification.Name?
    /// Posted by the host UI to clear all in-document find highlights.
    public var findClearHighlights: Notification.Name?

    public init(
        applyBoldRequest: Notification.Name? = nil,
        applyItalicRequest: Notification.Name? = nil,
        applyHeadingRequest: Notification.Name? = nil,
        selectionBoldDidChange: Notification.Name? = nil,
        selectionItalicDidChange: Notification.Name? = nil,
        findScrollToRange: Notification.Name? = nil,
        findClearHighlights: Notification.Name? = nil
    ) {
        self.applyBoldRequest = applyBoldRequest
        self.applyItalicRequest = applyItalicRequest
        self.applyHeadingRequest = applyHeadingRequest
        self.selectionBoldDidChange = selectionBoldDidChange
        self.selectionItalicDidChange = selectionItalicDidChange
        self.findScrollToRange = findScrollToRange
        self.findClearHighlights = findClearHighlights
    }

    public static let `default` = MarkdownEditorBus()
}

// MARK: - Services Container

/// Bundles every external service the engine needs.
///
/// Held by ``MarkdownEditorConfiguration/services``. The engine reads its
/// dependencies exclusively from this container; embedders inject the
/// implementations they want.
public struct MarkdownEditorServices: Sendable {
    public var images: any ImageProvider
    public var syntaxHighlighter: any SyntaxHighlighter
    public var latex: any LatexRenderer
    public var linkPreviews: any LinkPreviewProvider
    public var bus: MarkdownEditorBus

    public init(
        images: any ImageProvider = NoOpImageProvider(),
        syntaxHighlighter: any SyntaxHighlighter = PlainTextSyntaxHighlighter(),
        latex: any LatexRenderer = NoOpLatexRenderer(),
        linkPreviews: any LinkPreviewProvider = NoOpLinkPreviewProvider(),
        bus: MarkdownEditorBus = .default
    ) {
        self.images = images
        self.syntaxHighlighter = syntaxHighlighter
        self.latex = latex
        self.linkPreviews = linkPreviews
        self.bus = bus
    }

    /// Changes whenever an image or link preview the editor shows may have
    /// changed; the editor restyles when it does.
    var contentFingerprint: AnyHashable {
        AnyHashable([images.fingerprint(), linkPreviews.fingerprint()])
    }

    public static let `default` = MarkdownEditorServices()
}
