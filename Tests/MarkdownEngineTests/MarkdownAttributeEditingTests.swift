//
//  MarkdownAttributeEditingTests.swift
//  MarkdownEngineTests
//
//  Finding the image / link at the caret and rewriting its `{…}` block.
//

import Foundation
import Testing
@testable import MarkdownEngineCore

@Suite("Attribute editing")
struct MarkdownAttributeEditingTests {

    /// Applies `change` to the target at `location` and returns the new text.
    private func apply(_ text: String, at location: Int,
                       kinds: Set<MarkdownAttributeTarget.Kind> = [.image, .link, .bareURL],
                       _ change: @escaping (inout MarkdownAttributes) -> Void) -> String? {
        guard let target = MarkdownAttributeEditing.target(at: location, in: text, kinds: kinds),
              let edit = MarkdownAttributeEditing.edit(target, change: change) else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        // The result range covers the edited construct.
        let edited = (result as NSString).substring(with: edit.resultRange)
        #expect(edited.hasSuffix(")") || edited.hasSuffix("}"))
        return result
    }

    @Test func findsImageAtCaretIncludingItsEnd() throws {
        let text = "See ![cat](cat.png){.small} here"
        let inside = try #require(MarkdownAttributeEditing.target(at: 6, in: text))
        #expect(inside.kind == .image)
        #expect(inside.attributes.size == .small)
        #expect(inside.destination == "cat.png")
        #expect(inside.range == NSRange(location: 4, length: 15))
        #expect(inside.fullRange == NSRange(location: 4, length: 23))
        #expect(MarkdownAttributeEditing.target(at: 27, in: text)?.kind == .image)
        #expect(MarkdownAttributeEditing.target(at: 1, in: text) == nil)
    }

    @Test func insertsAttributeBlockWhenThereIsNone() {
        #expect(apply("![](a.png) x", at: 2, MarkdownAttributeEditing.setSize(.medium)) == "![](a.png){.medium} x")
    }

    @Test func replacesSizeKeepingOtherItems() {
        let text = #"![](a.png){#fig .small .center width=200 title="T"}"#
        #expect(apply(text, at: 3, MarkdownAttributeEditing.setSize(.full))
                == #"![](a.png){#fig .center title=T .full}"#)
    }

    @Test func iconSizeAndOriginalSize() {
        #expect(apply("![](a.png)", at: 0, MarkdownAttributeEditing.setSize(.icon)) == "![](a.png){.icon}")
        // "Original" clears the size; an empty block is removed.
        #expect(apply("![](a.png){.large}", at: 0, MarkdownAttributeEditing.setSize(nil)) == "![](a.png)")
    }

    @Test func noEditWhenNothingChanges() {
        #expect(apply("![](a.png){.small}", at: 0, MarkdownAttributeEditing.setSize(.small)) == nil)
    }

    @Test func alignmentReplacesThePreviousOne() {
        #expect(apply("![](a.png){.small .left}", at: 0, MarkdownAttributeEditing.setAlignment(.right))
                == "![](a.png){.small .right}")
        #expect(apply("![](a.png){.center}", at: 0, MarkdownAttributeEditing.setAlignment(nil)) == "![](a.png)")
    }

    @Test func linkPreviewToggle() {
        #expect(apply("Read [Doc](https://a.com) now", at: 7, MarkdownAttributeEditing.setPreview(true))
                == "Read [Doc](https://a.com){.preview} now")
        #expect(apply("[Doc](https://a.com){.preview .large #x}", at: 1, MarkdownAttributeEditing.setPreview(false))
                == "[Doc](https://a.com){#x}")
        // A size already means a card.
        #expect(apply("[Doc](https://a.com){.small}", at: 1, MarkdownAttributeEditing.setPreview(true)) == nil)
    }

    @Test func picksTheConstructUnderTheCaretAndHonorsKinds() {
        let text = "[Doc](https://a.com) and ![](a.png)"
        #expect(MarkdownAttributeEditing.target(at: 2, in: text)?.kind == .link)
        #expect(MarkdownAttributeEditing.target(at: 30, in: text)?.kind == .image)
        #expect(MarkdownAttributeEditing.target(at: 30, in: text, kinds: [.link]) == nil)
        #expect(MarkdownAttributeEditing.target(at: 2, in: text, kinds: [.image]) == nil)
    }

    @Test func bareURLBecomesACardLink() throws {
        let text = "Look https://example.com/x ok"
        let target = try #require(MarkdownAttributeEditing.target(at: 10, in: text))
        #expect(target.kind == .bareURL)
        #expect(target.destination == "https://example.com/x")
        #expect(apply(text, at: 10, MarkdownAttributeEditing.setPreview(true))
                == "Look [https://example.com/x](https://example.com/x){.preview} ok")
        // Turning a bare URL "off" is not an edit.
        #expect(apply(text, at: 10, MarkdownAttributeEditing.setPreview(false)) == nil)
    }

    @Test func urlsInsideCodeOrLinksAreNotBare() {
        #expect(MarkdownAttributeEditing.target(at: 5, in: "`https://a.com`") == nil)
        #expect(MarkdownAttributeEditing.target(at: 3, in: "a@b.com x") == nil)
    }

    @Test func worksOnLaterLines() {
        let text = "# Title\n\n![](a.png)\nnext"
        #expect(apply(text, at: 12, MarkdownAttributeEditing.setSize(.small)) == "# Title\n\n![](a.png){.small}\nnext")
    }
}
