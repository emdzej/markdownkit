//
//  FileDrop.swift
//  MarkdownEngine
//
//  Dropping files onto the editor. The engine collects the dropped files and
//  hands them to the embedder's `FileDropHandler`, which stores them wherever
//  it likes (e.g. an attachments folder next to the note) and returns the
//  markdown to insert at the drop point. The engine never writes files itself.
//

import Foundation
import UniformTypeIdentifiers

/// A file dropped onto the editor.
public struct DroppedFile: Sendable, Equatable {
    /// A readable local file. On iOS this is a temporary copy that the engine
    /// deletes after the handler returns, so copy it rather than keep the URL.
    public let url: URL
    /// The file's type, when known.
    public let contentType: UTType?
    /// The original file name (with extension).
    public let name: String

    public init(url: URL, contentType: UTType? = nil, name: String? = nil) {
        self.url = url
        self.contentType = contentType ?? UTType(filenameExtension: url.pathExtension)
        self.name = name ?? url.lastPathComponent
    }

    /// Whether the file is an image (rendered inline as `![](…)`).
    public var isImage: Bool { contentType?.conforms(to: .image) ?? false }

    /// Markdown pointing at the stored copy of this file: `![](path)` for
    /// images, `[name](path)` otherwise. `path` is relative to the note (or
    /// absolute); it is percent-encoded so spaces and parentheses can't break
    /// the link.
    public func markdownLink(to path: String) -> String {
        let destination = Self.encodeLinkDestination(path)
        if isImage { return "![](\(destination))" }
        let label = name.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(label)](\(destination))"
    }

    /// Percent-encodes a link destination; `/` stays readable.
    static func encodeLinkDestination(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()<> ")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}

/// Stores dropped files and returns the markdown to insert at the drop point,
/// or nil to ignore the drop. Runs on the main actor; may suspend while the
/// files are copied or uploaded.
public typealias FileDropHandler = @MainActor ([DroppedFile]) async -> String?
