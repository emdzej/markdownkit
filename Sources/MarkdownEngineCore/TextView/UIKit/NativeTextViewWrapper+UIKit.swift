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
    /// Called with the target of a tapped link (URL string or wiki-link name).
    public var onLinkClick: ((String) -> Void)?

    public init(
        text: Binding<String>,
        configuration: MarkdownEditorConfiguration = .default,
        fontName: String = "SF Pro",
        fontSize: CGFloat = 17,
        documentId: String = "default",
        isEditable: Bool = true,
        onLinkClick: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.documentId = documentId
        self.isEditable = isEditable
        self.onLinkClick = onLinkClick
    }

    public func makeCoordinator() -> MarkdownUICoordinator {
        MarkdownUICoordinator(text: $text, fontName: fontName, fontSize: fontSize)
    }

    public func makeUIView(context: Context) -> UIView {
        let tv = MarkdownUITextView()
        let coordinator = context.coordinator
        coordinator.configuration = configuration
        coordinator.onLinkClick = onLinkClick
        coordinator.documentId = documentId
        tv.delegate = coordinator
        tv.isEditable = isEditable
        apply(configuration, to: tv)
        coordinator.load(text, into: tv)
        return tv
    }

    public func updateUIView(_ view: UIView, context: Context) {
        guard let tv = view as? MarkdownUITextView else { return }
        let coordinator = context.coordinator
        coordinator.onLinkClick = onLinkClick

        let documentChanged = coordinator.documentId != documentId
        let fontChanged = coordinator.fontName != fontName || coordinator.fontSize != fontSize
        let editableChanged = tv.isEditable != isEditable
        coordinator.documentId = documentId
        coordinator.fontName = fontName
        coordinator.fontSize = fontSize
        coordinator.configuration = configuration
        tv.isEditable = isEditable
        apply(configuration, to: tv)

        if documentChanged || tv.string != text {
            coordinator.load(text, into: tv)
            if documentChanged { tv.setContentOffset(.zero, animated: false) }
        } else if fontChanged || editableChanged {
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
        tv.backgroundColor = .systemBackground
        tv.tintColor = configuration.theme.link
    }
}
#endif
