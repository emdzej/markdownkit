//
//  LinkPreviews.swift
//  MarkdownEngine
//
//  Link preview cards. A link marked `{.preview}` (or any size attribute)
//  asks the embedder's `LinkPreviewProvider` for its metadata and renders a
//  card in place of the link text. The engine only draws; fetching and
//  caching (LinkPresentation, QuickLook thumbnails, an index) are the
//  embedder's job. Like `ImageProvider`, lookups are synchronous: return
//  `.loading` while a fetch runs, then change `fingerprint()` so the editor
//  restyles with the result.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

/// What the editor knows about a link's target.
public struct LinkPreview: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        /// Metadata is available.
        case ready
        /// A fetch is running; the card shows the link text and destination.
        case loading
        /// The target can't be reached or doesn't exist; the link renders as
        /// plain text with an "unavailable" badge.
        case unavailable
    }

    public var status: Status
    /// Page or document title. Falls back to the link text.
    public var title: String?
    /// Description, or the first lines of a note.
    public var summary: String?
    /// Small muted line: host name, or file kind and size ("PDF · 2.4 MB").
    public var subtitle: String?
    /// Favicon or file icon.
    public var icon: PlatformImage?
    /// Hero image or thumbnail.
    public var image: PlatformImage?

    public init(
        status: Status = .ready,
        title: String? = nil,
        summary: String? = nil,
        subtitle: String? = nil,
        icon: PlatformImage? = nil,
        image: PlatformImage? = nil
    ) {
        self.status = status
        self.title = title
        self.summary = summary
        self.subtitle = subtitle
        self.icon = icon
        self.image = image
    }

    public static let loading = LinkPreview(status: .loading)
    public static let unavailable = LinkPreview(status: .unavailable)
}

/// What the engine asks a `LinkPreviewProvider` for.
public struct LinkPreviewRequest: Sendable, Equatable {
    /// The destination of `[text](destination)`, verbatim.
    public let destination: String
    /// The link text, as written (raw inline markdown).
    public let text: String
    /// The `{…}` attributes (size, alignment, …).
    public let attributes: MarkdownAttributes

    public init(destination: String, text: String, attributes: MarkdownAttributes) {
        self.destination = destination
        self.text = text
        self.attributes = attributes
    }
}

public protocol LinkPreviewProvider: Sendable {
    /// The preview for a link, or nil to render it as an ordinary link
    /// (e.g. web previews are turned off).
    func preview(for request: LinkPreviewRequest) -> LinkPreview?

    /// A coarse fingerprint of the provider's state; a new value restyles
    /// the editor, so change it when a fetch completes.
    func fingerprint() -> AnyHashable
}

/// Default provider: no previews, every link stays a plain link.
public struct NoOpLinkPreviewProvider: LinkPreviewProvider {
    public init() {}
    public func preview(for request: LinkPreviewRequest) -> LinkPreview? { nil }
    public func fingerprint() -> AnyHashable { 0 }
}
