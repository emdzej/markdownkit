#if os(iOS) || os(visionOS)
//
//  NativeTextViewWrapper+UIKit.swift
//  MarkdownEngine
//
//  SwiftUI entry point on iOS / iPadOS. Same type name as the AppKit
//  wrapper so multiplatform embedders write `NativeTextViewWrapper(text:)`
//  once. The UIKit surface is a subset for now; parameters are added as
//  their AppKit features get ported.
//

import SwiftUI
import UIKit

public struct NativeTextViewWrapper: UIViewRepresentable {
    @Binding public var text: String
    public var configuration: MarkdownEditorConfiguration
    public var fontName: String
    public var fontSize: CGFloat
    /// Stable per-document id; switching it reloads contents and resets the caret.
    public var documentId: String
    public var isEditable: Bool
    /// Called with the target of a tapped link (the markdown link destination).
    public var onLinkClick: ((String) -> Void)?
    /// Called with files dropped onto the editor. Store them (e.g. copy them
    /// into an attachments folder) and return the markdown to insert at the
    /// drop point — `DroppedFile.markdownLink(to:)` builds a link — or nil to
    /// ignore the drop. The `DroppedFile` URLs are temporary copies.
    public var onDropFiles: FileDropHandler?
    /// Addresses this editor from outside (insert text, focus).
    public var controller: MarkdownEditorController?

    public init(
        text: Binding<String>,
        configuration: MarkdownEditorConfiguration = .default,
        fontName: String = "SF Pro",
        fontSize: CGFloat = 17,
        documentId: String = "default",
        isEditable: Bool = true,
        controller: MarkdownEditorController? = nil,
        onDropFiles: FileDropHandler? = nil,
        onLinkClick: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.documentId = documentId
        self.isEditable = isEditable
        self.onLinkClick = onLinkClick
        self.onDropFiles = onDropFiles
        self.controller = controller
    }

    public func makeCoordinator() -> MarkdownUICoordinator {
        MarkdownUICoordinator(text: $text, fontName: fontName, fontSize: fontSize)
    }

    public func makeUIView(context: Context) -> UIView {
        let tv = MarkdownUITextView()
        // Find and replace (⌘F on a keyboard, or `MarkdownEditorController.showFind`).
        tv.isFindInteractionEnabled = true
        let coordinator = context.coordinator
        coordinator.configuration = configuration
        coordinator.onLinkClick = onLinkClick
        coordinator.documentId = documentId
        tv.delegate = coordinator
        tv.onDropFiles = onDropFiles
        tv.isEditable = isEditable
        controller?.textView = tv
        apply(configuration, to: tv)
        coordinator.load(text, into: tv)
        return tv
    }

    public func updateUIView(_ view: UIView, context: Context) {
        guard let tv = view as? MarkdownUITextView else { return }
        let coordinator = context.coordinator
        controller?.textView = tv
        coordinator.onLinkClick = onLinkClick
        tv.onDropFiles = onDropFiles

        let documentChanged = coordinator.documentId != documentId
        let fontChanged = coordinator.fontName != fontName || coordinator.fontSize != fontSize
        let editableChanged = tv.isEditable != isEditable
        let modeChanged = coordinator.configuration.renderingMode != configuration.renderingMode
            || coordinator.configuration.appearanceRevision != configuration.appearanceRevision
        let fingerprint = configuration.services.contentFingerprint
        let contentChanged = coordinator.lastContentFingerprint != nil && coordinator.lastContentFingerprint != fingerprint
        coordinator.lastContentFingerprint = fingerprint
        coordinator.documentId = documentId
        coordinator.fontName = fontName
        coordinator.fontSize = fontSize
        coordinator.configuration = configuration
        tv.isEditable = isEditable
        apply(configuration, to: tv)

        if documentChanged || tv.string != text {
            coordinator.load(text, into: tv)
            if documentChanged { tv.setContentOffset(.zero, animated: false) }
        } else if modeChanged {
            // Keep the line at the top of the viewport in place across the font change.
            let top = tv.closestPosition(to: CGPoint(x: tv.textContainerInset.left + 1, y: tv.contentOffset.y + tv.textContainerInset.top + 1))
            let topOffset = top.map { tv.caretRect(for: $0).minY - tv.contentOffset.y } ?? 0
            coordinator.revealedTableLocation = nil
            tv.removeAllTableOverlays()
            coordinator.rebuildAll(tv)
            if let top {
                tv.layoutIfNeeded()
                let y = tv.caretRect(for: top).minY - topOffset
                let maxY = max(-tv.adjustedContentInset.top, tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom)
                tv.setContentOffset(CGPoint(x: tv.contentOffset.x, y: min(max(y, -tv.adjustedContentInset.top), maxY)), animated: false)
            }
        } else if fontChanged || editableChanged || contentChanged {
            coordinator.rebuildAll(tv)
        }
    }

    private func apply(_ configuration: MarkdownEditorConfiguration, to tv: MarkdownUITextView) {
        tv.configuration = configuration
        let insets = configuration.textInsets
        tv.textContainerInset = UIEdgeInsets(
            top: max(insets.vertical, 12), left: max(insets.horizontal, 16),
            bottom: max(insets.vertical, 12), right: max(insets.horizontal, 16)
        )
        tv.spellCheckingType = configuration.spellChecking.continuousSpellChecking ? .yes : .no
        tv.autocorrectionType = configuration.spellChecking.automaticSpellingCorrection ? .yes : .no
        tv.backgroundColor = configuration.activeBackground ?? .systemBackground
        // Tint drives the caret and selection handles; selection fill follows it.
        tv.tintColor = configuration.theme.caret ?? configuration.theme.link
    }
}
#endif
