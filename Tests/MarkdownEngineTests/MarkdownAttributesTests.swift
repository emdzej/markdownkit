//
//  MarkdownAttributesTests.swift
//  MarkdownEngineTests
//
//  `{…}` attribute blocks after images and links: parsing, the inline
//  parser picking them up, image sizing, and how the styler uses them.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Testing
@testable import MarkdownEngineCore

@Suite("Markdown attributes")
struct MarkdownAttributesTests {

    private func r(_ l: Int, _ n: Int) -> NSRange { NSRange(location: l, length: n) }

    // MARK: Model

    @Test func parsesClassesIdsAndPairs() throws {
        let a = try #require(MarkdownAttributes(source: #"{.small #fig .center width=320 title="A \"b\""}"#))
        #expect(a.items == [.class("small"), .id("fig"), .class("center"),
                            .pair(key: "width", value: "320"), .pair(key: "title", value: #"A "b""#)])
        #expect(a.size == .small)
        #expect(a.alignment == .center)
        #expect(a.width == 320)
        #expect(a.wantsPreview)
    }

    @Test func rejectsNonAttributeText() {
        for source in ["{}", "{ }", "{small}", "{.}", "{width=}", "{.a,.b}", #"{t="open}"#, "{a b}"] {
            if source == "{}" || source == "{ }" {
                #expect(MarkdownAttributes(source: source)?.items == [])   // empty is valid, just inert
            } else {
                #expect(MarkdownAttributes(source: source) == nil, "\(source)")
            }
        }
    }

    @Test func lastSizeWinsAndUnknownClassesAreKept() throws {
        let a = try #require(MarkdownAttributes(source: "{.large .wobbly .small}"))
        #expect(a.size == .small)
        #expect(a.classes == ["large", "wobbly", "small"])
        #expect(!(try #require(MarkdownAttributes(source: "{.wobbly}"))).wantsPreview)
        #expect((try #require(MarkdownAttributes(source: "{.preview}"))).wantsPreview)
    }

    @Test func setSizeReplacesSizesAndRoundTrips() throws {
        var a = try #require(MarkdownAttributes(source: "{.small .center width=10 data-x=\"a b\"}"))
        a.setSize(.large)
        #expect(a.markdown() == #"{.center data-x="a b" .large}"#)
        #expect(MarkdownAttributes(source: a.markdown()) == a)
        a.items = []
        #expect(a.markdown() == "")
    }

    // MARK: Inline parser

    @Test func imageTakesTheAttributeBlockAsAFifthMarker() {
        #expect(InlineParser.parse("![a](u){.small}") == [
            .image(range: r(0, 15), alt: r(2, 1), url: r(5, 1),
                   markers: [r(0, 2), r(3, 1), r(4, 1), r(6, 1), r(7, 8)]),
        ])
    }

    @Test func linkTakesTheAttributeBlock() {
        #expect(InlineParser.parse("[a](u){.preview} x") == [
            .link(range: r(0, 16), textRange: r(1, 1), url: r(4, 1),
                  markers: [r(0, 1), r(2, 1), r(3, 1), r(5, 1), r(6, 10)], children: [.text(r(1, 1))]),
            .text(r(16, 2)),
        ])
    }

    @Test func invalidOrDetachedBracesStayText() {
        // Space before the brace, or brace content that isn't attributes.
        for text in ["[a](u) {.small}", "[a](u){not attrs}", "[a](u){.small"] {
            guard case .link(let range, _, _, let markers, _)? = InlineParser.parse(text).first else {
                Issue.record("no link in \(text)"); continue
            }
            #expect(range == r(0, 6), "\(text)")
            #expect(markers.count == 4, "\(text)")
        }
    }

    // MARK: Sizing

    private let style = ImageStyle.default
    private let photo = CGSize(width: 1000, height: 500)

    private func size(_ attrs: String, natural: CGSize? = nil, hint: CGFloat? = nil, max: CGFloat = 700) -> CGSize {
        style.displaySize(natural: natural ?? photo, attributes: MarkdownAttributes(source: attrs) ?? MarkdownAttributes(),
                          widthHint: hint, maxWidth: max, lineHeight: 20)
    }

    @Test func sizeKeywordsCapTheWidthAndKeepTheAspect() {
        #expect(size("{.small}") == CGSize(width: 160, height: 80))
        #expect(size("{.medium}") == CGSize(width: 320, height: 160))
        #expect(size("{.large}") == CGSize(width: 640, height: 320))
        #expect(size("{.full}") == CGSize(width: 700, height: 350))
        #expect(size("{.icon}") == CGSize(width: 40, height: 20))
        // Keywords never upscale a small image (except .full, which fills the column).
        #expect(size("{.large}", natural: CGSize(width: 100, height: 100)) == CGSize(width: 100, height: 100))
    }

    @Test func explicitPointsWinAndFitTheColumn() {
        #expect(size("{width=200}") == CGSize(width: 200, height: 100))
        #expect(size("{height=50}") == CGSize(width: 100, height: 50))
        #expect(size("{width=400 height=100}") == CGSize(width: 200, height: 100))   // fits the box
        #expect(size("{width=2000}") == CGSize(width: 700, height: 350))
        #expect(size("{.small width=300}") == CGSize(width: 300, height: 150))
    }

    @Test func noAttributesKeepsNaturalWidthAndTheObsidianHintApplies() {
        #expect(size("", natural: CGSize(width: 300, height: 150)) == CGSize(width: 300, height: 150))
        #expect(size("", hint: 120) == CGSize(width: 120, height: 60))
        #expect(size("{.small}", hint: 120) == CGSize(width: 160, height: 80))   // braces win
        #expect(ImageStyle.widthHint(alt: "photo|200") == 200)
        #expect(ImageStyle.widthHint(alt: "|200x100") == 200)
        #expect(ImageStyle.widthHint(alt: "a|b") == nil)
        #expect(ImageStyle.widthHint(alt: "plain") == nil)
    }

    // MARK: Styling

    struct SquareProvider: ImageProvider {
        func image(for request: ImageRequest) -> PlatformImage? {
            PlatformImage.mdDrawing(size: CGSize(width: 400, height: 400)) {}
        }
        func fingerprint() -> AnyHashable { 1 }
    }

    private func styled(_ text: String) -> [StyledRange] {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.images = SquareProvider()
        return MarkdownStyler.styleAttributes(
            text: text, fontName: "Helvetica", fontSize: 14,
            caretLocation: (text as NSString).length, activeTokenIndices: [], configuration: configuration
        )
    }

    private func imageBounds(_ attrs: [StyledRange]) -> [(Int, CGRect, Bool)] {
        attrs.compactMap { range, a in
            guard a[.latexImage] != nil, let b = (a[.latexBounds] as? NSValue)?.mdRect else { return nil }
            return (range.location, b, a[.latexIsBlock] as? Bool ?? false)
        }
    }

    @MainActor
    @Test func blockImageUsesItsSizeAndAlignment() throws {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let attrs = styled("Intro\n\n![](a.png){.small .center}\n\nOutro")
        let image = try #require(imageBounds(attrs).first)
        #expect(image.1.size == CGSize(width: 160, height: 160))
        #expect(image.2)
        // Centered in the fallback column (no layout bridge): (650 - 160) / 2.
        let indents = attrs.compactMap { ($0.1[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent }
        #expect(indents.contains(245))
    }

    @MainActor
    @Test func iconImageRendersInlineInsideText() throws {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let text = "Built with ![](swift.png){.icon} Swift"
        let attrs = styled(text)
        let image = try #require(imageBounds(attrs).first)
        #expect(image.0 == (text as NSString).range(of: "!").location)
        #expect(!image.2)
        let font = PlatformFont.md(named: "Helvetica", size: 14)
        #expect(abs(image.1.height - (font.ascender - font.descender)) < 0.01)
        #expect(image.1.width == image.1.height)
    }
}
