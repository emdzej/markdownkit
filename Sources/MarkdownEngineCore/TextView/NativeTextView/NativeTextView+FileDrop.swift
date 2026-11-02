#if os(macOS)
//
//  NativeTextView+FileDrop.swift
//  MarkdownEngine
//
//  Files dragged onto the editor (Finder, Mail, …) go to the embedder's
//  `onDropFiles` hook, which stores them and returns the markdown to insert
//  at the drop point. Other drags (text, in-document moves) keep NSTextView's
//  behaviour.
//

import AppKit
import UniformTypeIdentifiers

extension NativeTextView {

    /// File URLs on a drag pasteboard, if this drag should go to `onDropFiles`.
    private func droppedFiles(from pasteboard: NSPasteboard) -> [DroppedFile]? {
        guard onDropFiles != nil, isEditable,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return urls.map { url in
            DroppedFile(url: url, contentType: (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        return droppedFiles(from: sender.draggingPasteboard) != nil ? .copy : operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // super draws the insertion indicator at the hovered position.
        let operation = super.draggingUpdated(sender)
        return droppedFiles(from: sender.draggingPasteboard) != nil ? .copy : operation
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let files = droppedFiles(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        insertDroppedFiles(files, at: characterIndexForInsertion(at: point))
        return true
    }

    /// Passes `files` to `onDropFiles` and inserts the markdown it returns at
    /// `location` (clamped, since the document may change while it runs).
    func insertDroppedFiles(_ files: [DroppedFile], at location: Int) {
        guard let handler = onDropFiles else { return }
        window?.makeFirstResponder(self)
        Task { @MainActor [weak self] in
            guard let markdown = await handler(files), !markdown.isEmpty, let self else { return }
            self.insertMarkdown(markdown, replacing: NSRange(location: location, length: 0),
                                actionName: files.count == 1 ? "Insert File" : "Insert Files")
        }
    }

    /// Replaces `range` (clamped to the document) with `markdown` as one
    /// undoable edit, leaving the caret after it.
    func insertMarkdown(_ markdown: String, replacing range: NSRange, actionName: String) {
        let length = (string as NSString).length
        let start = min(max(range.location, 0), length)
        let target = NSRange(location: start, length: min(range.length, length - start))
        let inserted = NSRange(location: start, length: (markdown as NSString).length)
        breakUndoCoalescing()
        mdReplace(target, with: markdown)
        undoManager?.setActionName(EngineStrings.localized(actionName))
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: NSMaxRange(inserted), length: 0))
        // A programmatic insert leaves textDidChange no edited range to scope to.
        let ns = string as NSString
        coordinator?.restyleParagraphs([ns.paragraphRange(for: inserted)], in: self)
        updateWideTableOverlays()
    }
}
#endif
