//
//  MarkdownEditorTheme.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Color palette for the Markdown editor engine.
//
//  All user-visible colors used by the engine are routed through this
//  struct. Defaults map to system colors so the editor adapts to light/
//  dark mode automatically. Embedders that want a custom palette (for
//  example, a sepia or high-contrast preset) can replace any subset of
//  the colors without touching engine source files.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

// MARK: - Theme

/// Color palette consumed by the Markdown editor engine.
///
/// Every color the engine puts on screen is read from this struct, so a
/// single override is enough to retheme the entire editor. The defaults
/// reproduce a system-native macOS look using `PlatformColor` dynamic system
/// colors, so light/dark-mode switching keeps working without extra code.
public struct MarkdownEditorTheme: Sendable {

    // MARK: Text colors

    /// Foreground color for plain body text and the typing caret.
    public var bodyText: PlatformColor
    /// Foreground color for de-emphasized text and most syntax markers.
    /// Defaults to `secondaryLabelColor` so it tracks the system style.
    public var mutedText: PlatformColor
    /// Foreground color for content the engine wants to deemphasize further
    /// than `mutedText` — for example, unresolved references.
    public var disabledText: PlatformColor
    /// Foreground color for heading marker glyphs (`#`, `##`, …).
    public var headingMarker: PlatformColor

    // MARK: Links

    /// Foreground color for hyperlinks that resolve to an URL.
    public var link: PlatformColor
    /// Foreground color for incomplete `[text]` patterns (no URL yet).
    public var incompleteLink: PlatformColor

    // MARK: Find / search highlights

    /// Background color used to highlight all matches when the user is
    /// running an in-document search.
    ///
    /// The default is `.systemYellow` so embedders that don't customize
    /// this still get a sensible result. Apps with their own brand color
    /// (for example, the Nodes app uses its custom yellow) should override
    /// this to match their palette.
    public var findMatchHighlight: PlatformColor
    /// Background color used to highlight the currently-focused match
    /// during in-document search. Typically a stronger version of
    /// ``findMatchHighlight``.
    public var findCurrentMatchHighlight: PlatformColor

    // MARK: LaTeX rendering

    /// Foreground color used when rendering LaTeX formulas in light mode.
    public var latexLightModeText: PlatformColor
    /// Foreground color used when rendering LaTeX formulas in dark mode.
    public var latexDarkModeText: PlatformColor

    // MARK: Strikethrough / decoration

    /// Stroke color used for strikethrough decorations
    /// (e.g. completed task list items, horizontal rules).
    public var strikethroughColor: PlatformColor

    // MARK: Surfaces and blocks (nil keeps the built-in look)

    /// Editor background. nil: transparent on macOS (the host's background
    /// shows), `systemBackground` on iOS.
    public var background: PlatformColor?
    /// Heading text (the `#` markers use ``headingMarker``). nil: ``bodyText``.
    public var headingText: PlatformColor?
    /// PostScript name or design token (see ``MarkdownFontName``) for headings. nil: the body font.
    public var headingFontName: String?
    /// Inline `code` text. nil: the surrounding text color.
    public var inlineCodeText: PlatformColor?
    /// Blockquote bar. nil: ``mutedText`` at half opacity.
    public var blockquoteBar: PlatformColor?
    /// Blockquote text. nil: ``mutedText``.
    public var blockquoteText: PlatformColor?
    /// Horizontal rules. nil: ``strikethroughColor`` at 40 %.
    public var rule: PlatformColor?
    /// Table grid lines. nil: ``mutedText`` at 50 %.
    public var tableBorder: PlatformColor?
    /// Table header row fill. nil: ``link`` (the accent) at 12 %; see ``tableHeaderFill``.
    public var tableHeaderBackground: PlatformColor?
    /// Text selection. nil: the system selection color.
    public var selection: PlatformColor?
    /// Insertion point. nil: ``bodyText``.
    public var caret: PlatformColor?
    /// Frontmatter chip fill. nil: ``mutedText`` at 12 %.
    public var chipBackground: PlatformColor?
    /// Frontmatter `#tag` chips (text; fill at 12 %). nil: ``link``.
    public var tagChip: PlatformColor?
    /// Link preview card fill. nil: ``mutedText`` at 6 %.
    public var cardBackground: PlatformColor?
    /// Link preview card border. nil: ``mutedText`` at 35 %.
    public var cardBorder: PlatformColor?

    // MARK: Init

    public init(
        bodyText: PlatformColor = .mdLabel,
        mutedText: PlatformColor = .mdSecondaryLabel,
        disabledText: PlatformColor = .mdTertiaryLabel,
        headingMarker: PlatformColor = .gray,
        link: PlatformColor = .mdLink,
        incompleteLink: PlatformColor = .systemBlue,
        findMatchHighlight: PlatformColor = .systemYellow,
        findCurrentMatchHighlight: PlatformColor = .systemYellow,
        latexLightModeText: PlatformColor = .black,
        latexDarkModeText: PlatformColor = .white,
        strikethroughColor: PlatformColor = .mdLabel,
        background: PlatformColor? = nil,
        headingText: PlatformColor? = nil,
        headingFontName: String? = nil,
        inlineCodeText: PlatformColor? = nil,
        blockquoteBar: PlatformColor? = nil,
        blockquoteText: PlatformColor? = nil,
        rule: PlatformColor? = nil,
        tableBorder: PlatformColor? = nil,
        tableHeaderBackground: PlatformColor? = nil,
        selection: PlatformColor? = nil,
        caret: PlatformColor? = nil,
        chipBackground: PlatformColor? = nil,
        tagChip: PlatformColor? = nil,
        cardBackground: PlatformColor? = nil,
        cardBorder: PlatformColor? = nil
    ) {
        self.bodyText = bodyText
        self.mutedText = mutedText
        self.disabledText = disabledText
        self.headingMarker = headingMarker
        self.link = link
        self.incompleteLink = incompleteLink
        self.findMatchHighlight = findMatchHighlight
        self.findCurrentMatchHighlight = findCurrentMatchHighlight
        self.latexLightModeText = latexLightModeText
        self.latexDarkModeText = latexDarkModeText
        self.strikethroughColor = strikethroughColor
        self.background = background
        self.headingText = headingText
        self.headingFontName = headingFontName
        self.inlineCodeText = inlineCodeText
        self.blockquoteBar = blockquoteBar
        self.blockquoteText = blockquoteText
        self.rule = rule
        self.tableBorder = tableBorder
        self.tableHeaderBackground = tableHeaderBackground
        self.selection = selection
        self.caret = caret
        self.chipBackground = chipBackground
        self.tagChip = tagChip
        self.cardBackground = cardBackground
        self.cardBorder = cardBorder
    }

    /// The caret color in effect.
    public var caretColor: PlatformColor { caret ?? bodyText }

    /// System-native palette built from `PlatformColor` dynamic system colors.
    ///
    /// Use this if you want the engine to look like a stock macOS
    /// `NSTextView`. It's also the default when no theme is supplied.
    public static let `default` = MarkdownEditorTheme()
}

// MARK: - Font names

/// Font name tokens accepted wherever the engine takes a font name, besides
/// PostScript names: the system font in one of its designs.
public enum MarkdownFontName {
    public static let system = "system"
    /// New York.
    public static let serif = "system-serif"
    /// SF Mono.
    public static let monospaced = "system-mono"
    /// SF Rounded.
    public static let rounded = "system-rounded"
}

extension MarkdownEditorTheme {
    /// The header row fill: the theme's, or a light tint of the accent (link) color.
    public var tableHeaderFill: PlatformColor {
        tableHeaderBackground ?? link.withAlphaComponent(0.12)
    }
}
