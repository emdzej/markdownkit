//
//  ParseCacheGenerationTests.swift
//  MarkdownEngineTests
//
//  Adapted from swift-markdown-engine #96. `parsedDocument` answers cache
//  hits in O(1) from a character-edit generation of the text storage instead
//  of comparing the whole document. Upstream bumps that generation by hand in
//  the delegate callbacks; here it is driven by the storage's own
//  didProcessEditing, so these pin that every way of changing the text —
//  including direct storage edits that bypass the delegate and same-length
//  replacements the length check cannot see — invalidates the cache, and
//  that attribute-only restyles do not.
//

#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngineCore

@MainActor
@Suite("Parse cache generation")
struct ParseCacheGenerationTests {

    private func makeEditor(_ text: String) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro Text", fontSize: 14, onLinkClick: nil
        )
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        textView.configuration = .default
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        return (coordinator, textView)
    }

    /// Types `string` at `range` through the delegate path NSTextView uses
    /// (shouldChangeText → replace → didChangeText), without `insertText`,
    /// which drags the input-method XPC machinery into a windowless test run.
    private func type(_ string: String, at range: NSRange, in tv: NSTextView) {
        tv.setSelectedRange(range)
        guard tv.shouldChangeText(in: range, replacementString: string) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: string)
        tv.setSelectedRange(NSRange(location: range.location + (string as NSString).length, length: 0))
        tv.didChangeText()
    }

    private func kinds(_ c: NativeTextViewCoordinator, _ tv: NSTextView) -> [MarkdownTokenKind] {
        c.parsedDocument(for: tv.string).tokens.map(\.kind)
    }

    @Test func sameLengthDirectStorageEditInvalidatesTheCache() {
        let (c, tv) = makeEditor("plain **bold** text\n")
        #expect(kinds(c, tv).contains(.bold))

        // Same length, straight into the storage: no delegate callback, and the
        // length check alone would call it a hit.
        let stars = (tv.string as NSString).range(of: "**bold**")
        tv.textStorage?.replaceCharacters(in: stars, with: "``bold``")

        let after = kinds(c, tv)
        #expect(!after.contains(.bold))
        #expect(after.contains(.inlineCode))
        #expect(c.parsedDocument(for: tv.string).tokens.map(\.kind)
                == MarkdownTokenizer.parseTokensViaAST(in: tv.string).map(\.kind))
    }

    @Test func attributeOnlyRestyleKeepsTheCacheGeneration() {
        let (c, tv) = makeEditor("# Heading\n\nbody *text*\n")
        _ = c.parsedDocument(for: tv.string)
        let generation = c.cachedParseGeneration

        let ns = tv.string as NSString
        c.restyleTextView(tv, paragraphCandidates: [NSRange(location: 0, length: ns.length)])
        tv.textStorage?.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 3))
        _ = c.parsedDocument(for: tv.string)

        #expect(c.cachedParseGeneration == generation)
    }

    @Test func typedEditsReparse() {
        let (c, tv) = makeEditor("start\n")
        var at = 5
        for ch in [" ", "*", "x", "*"] {
            type(ch, at: NSRange(location: at, length: 0), in: tv)
            at += 1
        }
        #expect(tv.string == "start *x*\n")
        #expect(kinds(c, tv).contains(.italic))
    }

    @Test func untrackedStorageFallsBackToContentCompare() {
        let (c, tv) = makeEditor("one `two`\n")
        _ = c.parsedDocument(for: tv.string)
        // A coordinator with no text view can't use the O(1) path; same-length
        // different text must still miss.
        c.textView = nil
        let other = "one *two*\n"
        #expect(c.parsedDocument(for: other).tokens.map(\.kind)
                == MarkdownTokenizer.parseTokensViaAST(in: other).map(\.kind))
    }
}
#endif
