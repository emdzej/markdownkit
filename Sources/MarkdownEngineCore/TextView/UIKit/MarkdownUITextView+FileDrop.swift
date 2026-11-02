#if os(iOS) || os(visionOS)
//
//  MarkdownUITextView+FileDrop.swift
//  MarkdownEngine
//
//  Files dropped onto the editor (from Files, Photos, other apps) go to the
//  embedder's `onDropFiles` hook, which stores them and returns the markdown
//  to insert at the drop point. Drops of plain text keep UITextView's
//  behaviour.
//

import UIKit
import UniformTypeIdentifiers

extension MarkdownUITextView: UITextDropDelegate {

    /// A drop carries files when its items have file names (dragged text doesn't).
    private func isFileDrop(_ session: UIDropSession) -> Bool {
        onDropFiles != nil && isEditable && session.items.contains { $0.itemProvider.suggestedName != nil }
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        guard isFileDrop(drop.dropSession) else { return drop.suggestedProposal }
        let proposal = UITextDropProposal(operation: .copy)
        proposal.dropAction = .insert
        // We perform the drop ourselves (see willPerformDrop).
        proposal.dropPerformer = .delegate
        return proposal
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
        guard isFileDrop(drop.dropSession) else { return }
        let location = offset(from: beginningOfDocument, to: drop.dropPosition)
        let providers = drop.dropSession.items.map(\.itemProvider)
        Task { @MainActor [weak self] in
            let files = await Self.loadFiles(from: providers)
            defer { files.forEach { try? FileManager.default.removeItem(at: $0.url.deletingLastPathComponent()) } }
            guard !files.isEmpty else { return }
            await self?.insertDroppedFiles(files, at: location)
        }
    }

    /// Passes `files` to `onDropFiles` and inserts the markdown it returns at
    /// `location` (clamped, since the document may change while it runs).
    func insertDroppedFiles(_ files: [DroppedFile], at location: Int) async {
        guard let handler = onDropFiles,
              let markdown = await handler(files), !markdown.isEmpty else { return }
        insertMarkdown(markdown, replacing: NSRange(location: location, length: 0),
                       actionName: files.count == 1 ? "Insert File" : "Insert Files")
    }

    /// Replaces `range` (clamped to the document) with `markdown` as one
    /// undoable edit, leaving the caret after it.
    func insertMarkdown(_ markdown: String, replacing range: NSRange, actionName: String) {
        let length = (string as NSString).length
        let start = min(max(range.location, 0), length)
        let target = NSRange(location: start, length: min(range.length, length - start))
        let inserted = NSRange(location: start, length: (markdown as NSString).length)
        mdReplace(target, with: markdown)
        undoManager?.setActionName(EngineStrings.localized(actionName))
        selectedRange = NSRange(location: NSMaxRange(inserted), length: 0)
        markdownCoordinator?.programmaticEditDidChange(in: self, range: inserted)
    }

    /// Copies each provider's file into its own temporary folder: the URL a
    /// provider hands out is only valid inside its callback.
    private static func loadFiles(from providers: [NSItemProvider]) async -> [DroppedFile] {
        var files: [DroppedFile] = []
        for provider in providers {
            guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) })
                    ?? provider.registeredContentTypes.first else { continue }
            let suggestedName = provider.suggestedName
            let file: DroppedFile? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                    guard let url else { continuation.resume(returning: nil); return }
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("MarkdownEngineDrop-\(UUID().uuidString)", isDirectory: true)
                    var name = suggestedName ?? url.deletingPathExtension().lastPathComponent
                    if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                        name += ".\(ext)"
                    }
                    let copy = folder.appendingPathComponent(name)
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: copy)
                        continuation.resume(returning: DroppedFile(url: copy, contentType: type, name: name))
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let file { files.append(file) }
        }
        return files
    }
}
#endif
