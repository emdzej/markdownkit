//
//  MarkdownEditorController.swift
//  MarkdownEngine
//
//  A handle on one editor, for commands that come from outside it (a
//  "Link to Note" picker, toolbar buttons). Pass it to
//  `NativeTextViewWrapper(controller:)`; unlike the notification bus it
//  addresses exactly this editor, so several windows don't interfere.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

@MainActor
public final class MarkdownEditorController {
    #if os(macOS)
    weak var textView: NativeTextView?
    #else
    weak var textView: MarkdownUITextView?
    #endif

    public init() {}

    /// True once the editor's view exists.
    public var isAttached: Bool { textView != nil }

    /// The current selection (UTF-16 range in the markdown source).
    public var selectedRange: NSRange? {
        #if os(macOS)
        textView?.selectedRange()
        #else
        textView?.selectedRange
        #endif
    }

    /// Replaces the selection with `text` (raw markdown) as one undoable
    /// edit and puts the caret after it.
    public func insertText(_ text: String, actionName: String = "Insert") {
        guard let textView else { return }
        #if os(macOS)
        let selection = textView.selectedRange()
        #else
        let selection = textView.selectedRange
        #endif
        textView.insertMarkdown(text, replacing: selection, actionName: actionName)
    }

    /// Makes the editor first responder.
    public func focus() {
        #if os(macOS)
        textView?.window?.makeFirstResponder(textView)
        #else
        textView?.becomeFirstResponder()
        #endif
    }
}
