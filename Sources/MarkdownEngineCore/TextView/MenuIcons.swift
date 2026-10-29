//
//  MenuIcons.swift
//  MarkdownEngine
//
//  SF Symbols for the editor's menu items (context menus, table handles,
//  image / link markers), by title, so every menu shows icons the same way
//  on both platforms.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum MenuIcons {
    static func symbol(for title: String) -> String? {
        if title.hasPrefix("H"), title.count == 2, title.last?.isNumber == true { return "textformat.size" }
        return table[title]
    }

    #if os(macOS)
    static func image(for title: String) -> NSImage? {
        symbol(for: title).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }
    #else
    static func image(for title: String) -> UIImage? {
        symbol(for: title).flatMap { UIImage(systemName: $0) }
    }
    #endif

    private static let table: [String: String] = [
        // Text formatting
        "Format": "textformat", "Bold": "bold", "Italic": "italic", "Heading": "textformat.size",
        "Lists": "list.bullet", "Bullet": "list.bullet", "Numbered": "list.number",
        // Images and links
        "Image Size": "photo", "Card Size": "rectangle.portrait", "Align": "text.aligncenter",
        "Left": "text.alignleft", "Center": "text.aligncenter", "Right": "text.alignright",
        "Original": "photo", "Icon": "app", "Icon Only": "app", "Small": "s.square", "Medium": "m.square",
        "Large": "l.square", "Full Width": "arrow.left.and.right.square",
        "Show as Link": "link", "Show as Preview Card": "text.below.photo",
        // Tables
        "Insert Row Above": "arrow.up.to.line", "Insert Row Below": "arrow.down.to.line",
        "Insert Column Left": "arrow.left.to.line", "Insert Column Right": "arrow.right.to.line",
        "Delete Row": "trash", "Delete Column": "trash",
        "Move Row Up": "arrow.up", "Move Row Down": "arrow.down",
        "Move Column Left": "arrow.left", "Move Column Right": "arrow.right",
        "Align Left": "text.alignleft", "Align Center": "text.aligncenter", "Align Right": "text.alignright",
        "Fit Width to Content": "arrow.left.and.right", "Fit All Columns to Content": "arrow.left.and.right.square",
        "Edit as Markdown": "chevron.left.forwardslash.chevron.right",
    ]
}
