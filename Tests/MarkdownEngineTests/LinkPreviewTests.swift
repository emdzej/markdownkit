//
//  LinkPreviewTests.swift
//  MarkdownEngineTests
//
//  Link preview cards: which links become cards, card sizing, inline icons
//  and badges, and link destinations reaching `onLinkClick` unchanged.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Testing
@testable import MarkdownEngineCore

@MainActor
@Suite("Link previews")
struct LinkPreviewTests {

    struct Provider: LinkPreviewProvider {
        var preview: LinkPreview? = LinkPreview(title: "Swift", summary: "A language", subtitle: "swift.org")
        func preview(for request: LinkPreviewRequest) -> LinkPreview? { preview }
        func fingerprint() -> AnyHashable { 1 }
    }

    private func styled(_ text: String, _ provider: Provider = Provider(), caret: Int? = nil) -> [StyledRange] {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.linkPreviews = provider
        let ns = text as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let active = caret.map {
            MarkdownDetection.computeActiveTokenIndices(selectionRange: NSRange(location: $0, length: 0), tokens: tokens, in: ns)
        } ?? []
        return MarkdownStyler.styleAttributes(
            text: text, fontName: "Helvetica", fontSize: 14,
            caretLocation: caret ?? ns.length, activeTokenIndices: active,
            precomputedTokens: tokens, configuration: configuration
        )
    }

    private func pictures(_ attrs: [StyledRange]) -> [(location: Int, bounds: CGRect, block: Bool)] {
        attrs.compactMap { range, a in
            guard a[.latexImage] != nil, let b = (a[.latexBounds] as? NSValue)?.mdRect else { return nil }
            return (range.location, b, a[.latexIsBlock] as? Bool ?? false)
        }
    }

    @Test func standalonePreviewLinkBecomesACard() throws {
        let card = try #require(pictures(styled("Intro\n\n[Swift](https://swift.org){.preview}\n\nOutro")).first)
        #expect(card.block)
        #expect(card.bounds.width == LinkPreviewStyle.default.mediumWidth)
        #expect(card.bounds.height == LinkPreviewStyle.default.mediumHeight)
    }

    @Test func sizesPickTheCardWidth() throws {
        let style = LinkPreviewStyle.default
        let small = try #require(pictures(styled("[a](https://x.y){.small}")).first)
        #expect(small.bounds.width == style.smallWidth)
        #expect(small.bounds.height < style.mediumHeight)
        let explicit = try #require(pictures(styled("[a](https://x.y){width=200}")).first)
        #expect(explicit.bounds.width == 200)
    }

    @Test func linksWithoutPreviewOrInsideTextStayPlain() {
        #expect(pictures(styled("[a](https://x.y)")).isEmpty)
        #expect(pictures(styled("[a](https://x.y){.wobbly}")).isEmpty)
        #expect(pictures(styled("see [a](https://x.y){.preview} here")).isEmpty)
        #expect(pictures(styled("[a](https://x.y){.preview}", Provider(preview: nil))).isEmpty)
    }

    @Test func caretOnTheLinkShowsSourceWithTheCardBelow() throws {
        let attrs = styled("[Swift](https://swift.org){.preview}", caret: 2)
        let card = try #require(pictures(attrs).first)
        #expect(card.block)
        // Source visible: the attribute block is not collapsed to clear text.
        let attrBlock = ("[Swift](https://swift.org){.preview}" as NSString).range(of: "{.preview}")
        let hidden = attrs.contains { NSLocationInRange(attrBlock.location, $0.0) && ($0.1[.foregroundColor] as? PlatformColor) == .clear }
        #expect(!hidden)
    }

    @Test func iconLinksKeepTheirTextAfterAnInlineIcon() throws {
        let text = "Read [Swift](https://swift.org){.icon} today"
        let icon = try #require(pictures(styled(text)).first)
        #expect(!icon.block)
        #expect(icon.location == (text as NSString).range(of: "[").location)
    }

    @Test func unavailableTargetsGetABadgeNotACard() throws {
        let text = "[Gone](missing.md){.preview}"
        let badge = try #require(pictures(styled(text, Provider(preview: .unavailable))).first)
        #expect(!badge.block)
        #expect(badge.location == (text as NSString).range(of: "{").location)
    }

    @Test func linkDestinationsStayAsWritten() {
        #expect(MarkdownASTStyler.linkURL("Projects/My%20Idea.md")?.absoluteString == "Projects/My%20Idea.md")
        #expect(MarkdownASTStyler.linkURL("mailto:a@b.c")?.absoluteString == "mailto:a@b.c")
        #expect(MarkdownASTStyler.linkURL("https://swift.org")?.absoluteString == "https://swift.org")
        #expect(MarkdownASTStyler.linkURL("www.swift.org")?.absoluteString == "https://www.swift.org")
    }

    @Test func loadingCardsFallBackToTheLinkText() {
        let request = LinkPreviewRequest(destination: "https://www.swift.org/blog/", text: "Blog", attributes: MarkdownAttributes())
        let content = LinkCardContent(.loading, request: request)
        #expect(content.title == "Blog")
        #expect(content.subtitle == "swift.org")
        let file = LinkCardContent(.loading, request: LinkPreviewRequest(destination: "_attachments/Q3%20report.pdf", text: "", attributes: MarkdownAttributes()))
        #expect(file.title == "_attachments/Q3%20report.pdf")
        #expect(file.subtitle == "Q3 report.pdf")
    }
}
