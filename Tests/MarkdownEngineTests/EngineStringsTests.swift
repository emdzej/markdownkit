//
//  EngineStringsTests.swift
//  MarkdownEngineTests
//
//  The editor's menu titles have Polish translations, and titles without
//  one are shown as written.
//

import Foundation
import Testing
@testable import MarkdownEngineCore

@Suite("Engine strings")
struct EngineStringsTests {
    private var polish: Bundle {
        get throws { try #require(EngineStrings.bundle.path(forResource: "pl", ofType: "lproj").flatMap(Bundle.init(path:))) }
    }

    @Test func everyMenuTitleIsTranslated() throws {
        let polish = try polish
        let missing = MenuIcons.titles.filter { title in
            !(title.count == 2 && title.hasPrefix("H")) && polish.localizedString(forKey: title, value: "∅", table: nil) == "∅"
        }
        #expect(missing.isEmpty, "No Polish for: \(missing.sorted())")
        #expect(polish.localizedString(forKey: "Delete Row", value: nil, table: nil) == "Usuń wiersz")
    }

    @Test func unknownTitlesStayAsWritten() {
        #expect(EngineStrings.localized("Link to Note") == "Link to Note")
    }
}
