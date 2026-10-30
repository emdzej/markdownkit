//
//  ListHandlerCodeContextTests.swift
//  MarkdownEngineTests
//
//  Ported from swift-markdown-engine #96. The list handler gets "is the caret
//  in code?" from the keystroke's parse (codeTokens) instead of a
//  full-document contains("`") + tokenizer scan on every space/Enter/Tab.
//  These pin that list continuation still fires outside code and stays inert
//  inside a fenced block, through the production delegate path
//  (driven via shouldChangeText/didChangeText rather than `insertText`).
//

#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngineCore

@MainActor
@Suite("List handler code-block context")
struct ListHandlerCodeContextTests {

    private func makeEditor(text: String) -> (NativeTextViewCoordinator, NativeTextView) {
        _ = NSApplication.shared
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.configuration = .default
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro Text", fontSize: 14, onLinkClick: nil
        )
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.string = text
        coordinator.lastSyncedText = text
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

    @Test func enterContinuesListOutsideCode() {
        let (_, tv) = makeEditor(text: "- hello")
        type("\n", at: NSRange(location: 7, length: 0), in: tv)

        #expect(tv.string == "- hello\n- ")
    }

    @Test func enterDoesNotContinueListInsideFencedCode() {
        let text = "```\n- hello\n```"
        let (_, tv) = makeEditor(text: text)
        // End of "- hello", inside the fence.
        type("\n", at: NSRange(location: 11, length: 0), in: tv)

        #expect(tv.string == "```\n- hello\n\n```")
    }

    @Test func enterAtUnclosedFenceOpenerAddsTheCloser() {
        let text = "intro\n```swift"
        let (_, tv) = makeEditor(text: text)
        let end = (text as NSString).length
        type("\n", at: NSRange(location: end, length: 0), in: tv)

        #expect(tv.string.hasPrefix("intro\n```swift\n"))
        #expect(tv.string.hasSuffix("```"))
        #expect(MarkdownDetection.tripleBacktickCount(in: tv.string as NSString) == 2)
    }
}
#endif
