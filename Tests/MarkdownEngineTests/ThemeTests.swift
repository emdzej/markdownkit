//
//  ThemeTests.swift
//  MarkdownEngineTests
//
//  Theme colors and font tokens reaching the styled attributes, in both
//  rendering modes; nil theme fields keep the built-in look.
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
@Suite("Themes")
struct ThemeTests {

    private func styled(_ text: String, caret: Int = 0, fontName: String = "Helvetica", configure: (inout MarkdownEditorConfiguration) -> Void) -> [StyledRange] {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        var configuration = MarkdownEditorConfiguration.default
        configure(&configuration)
        let ns = text as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caret, length: 0), tokens: tokens, in: ns)
        return MarkdownStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: 14,
            caretLocation: caret, activeTokenIndices: active,
            precomputedTokens: tokens, configuration: configuration
        )
    }

    /// The last value set for `key` at `location` (later ranges win when applied in order).
    private func value(_ key: NSAttributedString.Key, at location: Int, in attrs: [StyledRange]) -> Any? {
        attrs.last { NSLocationInRange(location, $0.range) && $0.attributes[key] != nil }?.attributes[key]
    }

    @Test func headingColorAndFont() {
        let text = "Body\n\n# Title\n"
        let attrs = styled(text) {
            $0.theme.headingText = .systemRed
            $0.theme.headingFontName = MarkdownFontName.serif
        }
        let title = (text as NSString).range(of: "Title").location
        #expect(value(.foregroundColor, at: title, in: attrs) as? PlatformColor == .systemRed)
        let font = value(.font, at: title, in: attrs) as? PlatformFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font?.fontName != PlatformFont.systemFont(ofSize: 14).fontName)
    }

    @Test func defaultsLeaveHeadingsInBodyColor() {
        let text = "Body\n\n# Title\n"
        let attrs = styled(text) { _ in }
        let title = (text as NSString).range(of: "Title").location
        #expect(value(.foregroundColor, at: title, in: attrs) == nil)
    }

    @Test func inlineCodeAndQuoteColors() {
        let text = "Some `code` here\n\n> quoted\n"
        let attrs = styled(text, caret: 0) {
            $0.theme.inlineCodeText = .systemGreen
            $0.theme.blockquoteText = .systemBrown
        }
        let ns = text as NSString
        #expect(value(.foregroundColor, at: ns.range(of: "code").location, in: attrs) as? PlatformColor == .systemGreen)
        #expect(value(.foregroundColor, at: ns.range(of: "quoted").location, in: attrs) as? PlatformColor == .systemBrown)
    }

    @Test func sourceModeColors() {
        let text = "Plain **bold** [link](https://a.b)\n"
        let attrs = styled(text) {
            $0.renderingMode = .source
            $0.source.textColor = .systemTeal
            $0.source.markerColor = .systemGray
            $0.source.emphasisColor = .systemIndigo
            $0.source.linkColor = .systemMint
            $0.source.urlColor = .systemYellow
        }
        let ns = text as NSString
        #expect(value(.foregroundColor, at: 0, in: attrs) as? PlatformColor == .systemTeal)
        #expect(value(.foregroundColor, at: ns.range(of: "**").location, in: attrs) as? PlatformColor == .systemGray)
        #expect(value(.foregroundColor, at: ns.range(of: "bold").location, in: attrs) as? PlatformColor == .systemIndigo)
        #expect(value(.foregroundColor, at: ns.range(of: "link").location, in: attrs) as? PlatformColor == .systemMint)
        #expect(value(.foregroundColor, at: ns.range(of: "https").location, in: attrs) as? PlatformColor == .systemYellow)
    }

    @Test func fontTokensResolveToSystemDesigns() {
        let serif = PlatformFont.md(named: MarkdownFontName.serif, size: 15)
        let mono = PlatformFont.md(named: MarkdownFontName.monospaced, size: 15)
        let system = PlatformFont.md(named: MarkdownFontName.system, size: 15)
        #expect(serif.pointSize == 15)
        #expect(serif.fontName != system.fontName)
        #expect(mono.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(system.fontName == PlatformFont.systemFont(ofSize: 15).fontName)
    }

    @Test func activeBackgroundFollowsMode() {
        var configuration = MarkdownEditorConfiguration.default
        #expect(configuration.activeBackground == nil)
        configuration.theme.background = .systemPink
        #expect(configuration.activeBackground == .systemPink)
        configuration.renderingMode = .source
        #expect(configuration.activeBackground == .systemPink)
        configuration.source.background = .systemBlue
        #expect(configuration.activeBackground == .systemBlue)
    }
}
