#if os(iOS) || os(visionOS)
//
//  MarkdownUITextView+Paste.swift
//  MarkdownEngine
//
//  Pasting images (a screenshot, an image copied in Photos or Safari) goes
//  to the embedder's `onPasteImage` hook, which stores them and returns the
//  markdown to insert on its own line, as on macOS. Everything else keeps
//  UITextView's paste.
//

import UIKit

extension MarkdownUITextView {

    override func paste(_ sender: Any?) {
        if isEditable, let hook = onPasteImage, UIPasteboard.general.hasImages,
           let markdown = hook(.general), !markdown.isEmpty {
            let selection = selectedRange
            insertMarkdown(BlockInsertion.padded(markdown, replacing: selection, in: string as NSString),
                           replacing: selection, actionName: "Paste Image")
            return
        }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // UITextView offers Paste for text only. `hasImages` doesn't read
        // the pasteboard, so it doesn't trigger the paste permission prompt.
        if action == #selector(paste(_:)), isEditable, onPasteImage != nil, UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
#endif
