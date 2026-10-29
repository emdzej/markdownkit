//
//  SourceModeAndFrontmatterTests.swift
//  MarkdownEngineTests
//
//  Frontmatter parsing (a block only at the document start, CRLF, incremental
//  edits), its collapsed chips and reveal, and `.source` mode styling.
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
@Suite("Frontmatter and source mode")
struct SourceModeAndFrontmatterTests {

    private func styled(_ text: String, caret: Int, mode: RenderingMode = .formatted) -> [StyledRange] {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        var configuration = MarkdownEditorConfiguration.default
        configuration.renderingMode = mode
        let ns = text as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caret, length: 0), tokens: tokens, in: ns)
        return MarkdownStyler.styleAttributes(
            text: text, fontName: "Helvetica", fontSize: 14,
            caretLocation: caret, activeTokenIndices: active,
            precomputedTokens: tokens, configuration: configuration
        )
    }

    private func pictures(_ attrs: [StyledRange]) -> [Int] {
        attrs.compactMap { range, a in a[.latexImage] != nil ? range.location : nil }
    }

    /// The last value set for `key` at `location` (later ranges win when applied in order).
    private func value(_ key: NSAttributedString.Key, at location: Int, in attrs: [StyledRange]) -> Any? {
        attrs.last { NSLocationInRange(location, $0.range) && $0.attributes[key] != nil }?.attributes[key]
    }

    // MARK: Parsing

    @Test func frontmatterIsOneBlockAtTheStart() {
        let text = "---\npinned: true\n---\n# Title\n"
        let blocks = BlockParser.parse(text)
        #expect(blocks.first == Block(kind: .frontmatter, range: NSRange(location: 0, length: 21)))
        #expect(blocks.dropFirst().first?.kind == .heading)
        let token = MarkdownTokenizer.parseTokensViaAST(in: text).first { $0.kind == .frontmatter }
        #expect(token?.range == NSRange(location: 0, length: 20))
        #expect(token?.contentRange == NSRange(location: 4, length: 13))
        #expect(token?.markerRanges == [NSRange(location: 0, length: 3), NSRange(location: 17, length: 3)])
    }

    @Test func rulesElsewhereStayRules() {
        #expect(BlockParser.parse("a\n---\nb: c\n---\n").allSatisfy { $0.kind != .frontmatter })
        // Starts with a rule, but what follows isn't YAML.
        #expect(BlockParser.parse("---\nJust text\n---\n").first?.kind == .thematicBreak)
        // No closing fence.
        #expect(BlockParser.parse("---\ntitle: x\n").first?.kind == .thematicBreak)
    }

    @Test func crlfAndDotsCloseIt() {
        #expect(BlockParser.parse("---\r\ntags: [a]\r\n---\r\nBody").first?.kind == .frontmatter)
        #expect(BlockParser.parse("---\ntitle: x\n...\nBody").first?.kind == .frontmatter)
    }

    @Test func editsKeepTheBlocksRight() {
        // Incremental reparses must agree with a fresh parse.
        let steps = ["Body\n\n---\n", "---\ntitle: x\nBody\n\n---\n", "---\ntitle: x\n---\nBody\n\n---\n",
                     "---\ntitle: x\n---\nBody\n\nMore\n", "--\ntitle: x\n---\nBody\n\nMore\n"]
        var incremental: [[Block]] = []
        for text in steps { incremental.append(BlockParser.parse(text)) }   // each parse diffs against the previous
        for (text, blocks) in zip(steps, incremental) {
            _ = BlockParser.parse("")   // an empty previous text forces a full parse
            #expect(blocks == BlockParser.parse(text), "\(text.debugDescription)")
        }
        #expect(incremental[1].first?.kind == .frontmatter)   // closed by the later rule
        #expect(incremental[3].first?.kind == .frontmatter)
        #expect(incremental[4].first?.kind != .frontmatter)
    }

    @Test func propertiesAndChips() {
        let props = FrontmatterProperties("pinned: true\ntags: [work, \"#ideas\"]\nauthor: Ann\naliases:\n  - One\n  - Two\n")
        #expect(props.chips == [.pinned, .tag("work"), .tag("ideas"), .property(key: "author", value: "Ann"),
                                .property(key: "aliases", value: "One, Two")])
        #expect(FrontmatterProperties("").chips == [.empty])
        #expect(FrontmatterProperties("tags:\n- a\n- b\n").chips == [.tag("a"), .tag("b")])
    }

    // MARK: Formatted mode

    @Test func collapsedUntilTheCaretIsInside() {
        let text = "---\npinned: true\n---\nBody"
        // A caret at 0 (where notes open) or in the body: one picture, raw text hidden.
        for caret in [0, (text as NSString).length] {
            let attrs = styled(text, caret: caret)
            #expect(pictures(attrs) == [4])
            #expect((value(.foregroundColor, at: 8, in: attrs) as? PlatformColor) == .clear)
        }
        // Caret inside: raw lines, no picture, the key colored.
        let attrs = styled(text, caret: 6)
        #expect(pictures(attrs).isEmpty)
        #expect((value(.foregroundColor, at: 4, in: attrs) as? PlatformColor) == SourceModeStyle.default.keyColor)
        #expect((value(.foregroundColor, at: 0, in: attrs) as? PlatformColor) == MarkdownEditorTheme.default.mutedText)
    }

    @Test func emptyFrontmatterStillCollapses() {
        #expect(pictures(styled("---\n---\nBody", caret: 10)) == [0])
    }

    @Test func notParsedAsHeadingOrRule() {
        let attrs = styled("---\ntitle: x\n---\nBody", caret: 0)
        #expect(!attrs.contains { $0.attributes[.thematicBreak] != nil })
    }

    // MARK: Source mode

    @Test func sourceModeShowsEverythingAsTyped() {
        let text = "---\ntitle: x\n---\n# Head\n\n**bold** [a](b.md){.small} ![i](p.png)\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [ ] task\n\n---\n"
        let attrs = styled(text, caret: 0, mode: .source)
        #expect(pictures(attrs).isEmpty)
        // Nothing hidden: no clear text, no kerning, no bullet / checkbox / rule decorations.
        #expect(!attrs.contains { ($0.attributes[.foregroundColor] as? PlatformColor) == .clear })
        #expect(!attrs.contains { $0.attributes[.kern] != nil })
        #expect(!attrs.contains { $0.attributes[.bulletMarker] != nil || $0.attributes[.taskCheckbox] != nil || $0.attributes[.thematicBreak] != nil })
        #expect(!attrs.contains { $0.attributes[.link] != nil })

        let ns = text as NSString
        let heading = ns.range(of: "# Head")
        let headingFont = value(.font, at: heading.location + 2, in: attrs) as? PlatformFont
        #expect(headingFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect((value(.foregroundColor, at: heading.location + 2, in: attrs) as? PlatformColor) == MarkdownEditorTheme.default.link)
        let attribute = ns.range(of: "{.small}")
        #expect((value(.foregroundColor, at: attribute.location + 1, in: attrs) as? PlatformColor) == SourceModeStyle.default.attributeColor)
        let marker = ns.range(of: "**")
        #expect((value(.foregroundColor, at: marker.location, in: attrs) as? PlatformColor) == MarkdownEditorTheme.default.mutedText)
        let key = ns.range(of: "title")
        #expect((value(.foregroundColor, at: key.location, in: attrs) as? PlatformColor) == SourceModeStyle.default.keyColor)
    }

    @Test func sourceModeUsesAMonospacedBaseFont() {
        var configuration = MarkdownEditorConfiguration.default
        configuration.renderingMode = .source
        let font = TextStylingService.makeBaseFontAndStyle(fontName: "Helvetica", fontSize: 14, configuration: configuration).font
        #if os(macOS)
        let mono = PlatformFontDescriptor.SymbolicTraits.monoSpace
        #else
        let mono = PlatformFontDescriptor.SymbolicTraits.traitMonoSpace
        #endif
        #expect(font.fontDescriptor.symbolicTraits.contains(mono))
        let formatted = TextStylingService.makeBaseFontAndStyle(fontName: "Helvetica", fontSize: 14).font
        #expect(!formatted.fontDescriptor.symbolicTraits.contains(mono))
    }
}
