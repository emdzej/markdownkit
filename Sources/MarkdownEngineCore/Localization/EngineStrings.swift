//
//  EngineStrings.swift
//  MarkdownEngineCore
//
//  The editor's own menu titles and undo names, translated where they're
//  shown. Code keeps the English titles (MenuIcons looks icons up by them);
//  `Resources/Localizable.xcstrings` has the translations. A title without
//  one, such as an undo name the app already translated, is shown as is.
//

import Foundation

enum EngineStrings {
    static func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static var bundle: Bundle { .module }
}
