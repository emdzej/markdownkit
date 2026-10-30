//
//  BlockInsertion.swift
//  MarkdownEngine
//
//  Pasted images are block content: on its own line the image renders as a
//  block, mid-paragraph it would render inline. Shared by both platforms'
//  paste handling.
//

import Foundation

enum BlockInsertion {
    /// `markdown` with the line breaks it needs to sit on its own line when
    /// it replaces `range` in `text`.
    static func padded(_ markdown: String, replacing range: NSRange, in text: NSString) -> String {
        let start = min(max(range.location, 0), text.length)
        let end = min(start + max(range.length, 0), text.length)
        let prefix = start > 0 && text.character(at: start - 1) != 0x0A ? "\n" : ""
        let suffix = end < text.length && text.character(at: end) != 0x0A ? "\n" : ""
        return prefix + markdown + suffix
    }
}
