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

    /// Selects `range` (UTF-16, clamped) and scrolls it into view, e.g. to
    /// jump to a heading from an outline.
    public func reveal(_ range: NSRange) {
        guard let textView else { return }
        let length = (textView.string as NSString).length
        let start = min(max(range.location, 0), length)
        let clamped = NSRange(location: start, length: min(range.length, length - start))
        textView.setSelectedRange(clamped)
        textView.scrollRangeToVisible(clamped)
        focus()
    }

    // MARK: Image and link attributes

    /// The image, link or bare URL at the selection's start, e.g. to enable
    /// and check "Image Size" / "Show as Preview Card" menu items.
    public var attributeTarget: MarkdownAttributeTarget? {
        guard let textView else { return nil }
        #if os(macOS)
        let location = textView.selectedRange().location
        #else
        let location = textView.selectedRange.location
        #endif
        return MarkdownAttributeEditing.target(at: location, in: textView.string)
    }

    /// Sets the size of the image at the selection (`nil` = original size).
    /// Returns false when there's no image there or nothing changed.
    @discardableResult
    public func setImageSize(_ size: MarkdownAttributes.Size?) -> Bool {
        apply(.size(size), kinds: [.image])
    }

    /// Sets the size of the preview card at the selection (`.icon` shows the
    /// link with its site icon instead).
    @discardableResult
    public func setLinkCardSize(_ size: MarkdownAttributes.Size?) -> Bool {
        guard attributeTarget?.isPreview == true else { return false }
        return apply(.size(size), kinds: [.link])
    }

    /// Aligns the image or preview card at the selection (`nil` = left).
    @discardableResult
    public func setAlignment(_ alignment: MarkdownAttributes.Alignment?) -> Bool {
        apply(.align(alignment), kinds: [.image, .link])
    }

    /// Shows the link (or bare URL) at the selection as a preview card, or
    /// back as a plain link.
    @discardableResult
    public func setLinkPreview(_ on: Bool) -> Bool {
        apply(.preview(on), kinds: [.link, .bareURL])
    }

    private func apply(_ action: MarkerAction, kinds: Set<MarkdownAttributeTarget.Kind>) -> Bool {
        guard let textView else { return false }
        #if os(macOS)
        let location = textView.selectedRange().location
        #else
        let location = textView.selectedRange.location
        #endif
        return textView.applyMarkerAction(action, at: location, kinds: kinds)
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
