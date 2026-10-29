//
//  MarkdownEditorConfiguration.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Centralized configuration for the Markdown editor engine.
//
//  This struct exposes every spacing, sizing, and behavior knob that is
//  shared across the engine. The defaults reproduce the historical
//  Nodes-app behavior, so passing `.default` keeps existing rendering
//  pixel-identical. Embedders that want a different look-and-feel can
//  override individual fields without forking the engine.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

// MARK: - Top-level Configuration

/// All tunable values for the Markdown editor engine grouped by concern.
///
/// The struct is deliberately flat-with-nested-groups: top level holds
/// orthogonal feature areas (markers, code blocks, lists, …), each group
/// owns the values that belong together. Default values are the production
/// defaults used by the Nodes app and have been chosen empirically.
public struct MarkdownEditorConfiguration: Sendable {

    public var theme: MarkdownEditorTheme
    public var services: MarkdownEditorServices
    public var markers: MarkerStyle
    public var codeBlock: CodeBlockStyle
    public var inlineCode: InlineCodeStyle
    public var lists: ListStyle
    public var headings: HeadingStyle
    public var images: ImageStyle
    public var linkPreviews: LinkPreviewStyle
    public var blockLatex: BlockLatexStyle
    public var inlineLatex: InlineLatexStyle
    public var checkbox: CheckboxStyle
    public var link: LinkStyle
    public var paragraph: ParagraphStyle
    public var overscroll: OverscrollPolicy
    public var dragSelection: DragSelectionPolicy
    public var safeAreaInsets: SafeAreaInsets
    public var scrollers: ScrollersPolicy
    public var textInsets: TextInsets
    /// Bump when the theme, fonts or highlighter change in ways the engine
    /// can't compare (colors are dynamic objects): the editor restyles the
    /// whole document in place, keeping selection and scroll position.
    public var appearanceRevision: String = ""
    /// Centered reading-column width; wide tables break out to full width. nil = full width (default).
    public var readingWidth: CGFloat?
    public var spellChecking: SpellCheckingPolicy
    /// Formatted (markdown blended with rendering) or plain highlighted source.
    public var renderingMode: RenderingMode
    /// The look of `.source` mode (and of revealed frontmatter).
    public var source: SourceModeStyle

    public init(
        theme: MarkdownEditorTheme = .default,
        services: MarkdownEditorServices = .default,
        markers: MarkerStyle = .default,
        codeBlock: CodeBlockStyle = .default,
        inlineCode: InlineCodeStyle = .default,
        lists: ListStyle = .default,
        headings: HeadingStyle = .default,
        images: ImageStyle = .default,
        linkPreviews: LinkPreviewStyle = .default,
        blockLatex: BlockLatexStyle = .default,
        inlineLatex: InlineLatexStyle = .default,
        checkbox: CheckboxStyle = .default,
        link: LinkStyle = .default,
        paragraph: ParagraphStyle = .default,
        overscroll: OverscrollPolicy = .default,
        dragSelection: DragSelectionPolicy = .default,
        safeAreaInsets: SafeAreaInsets = .default,
        scrollers: ScrollersPolicy = .default,
        textInsets: TextInsets = .default,
        readingWidth: CGFloat? = nil,
        spellChecking: SpellCheckingPolicy = .default,
        renderingMode: RenderingMode = .formatted,
        source: SourceModeStyle = .default
    ) {
        self.theme = theme
        self.services = services
        self.markers = markers
        self.codeBlock = codeBlock
        self.inlineCode = inlineCode
        self.lists = lists
        self.headings = headings
        self.images = images
        self.linkPreviews = linkPreviews
        self.blockLatex = blockLatex
        self.inlineLatex = inlineLatex
        self.checkbox = checkbox
        self.link = link
        self.paragraph = paragraph
        self.overscroll = overscroll
        self.dragSelection = dragSelection
        self.safeAreaInsets = safeAreaInsets
        self.scrollers = scrollers
        self.textInsets = textInsets
        self.readingWidth = readingWidth
        self.spellChecking = spellChecking
        self.renderingMode = renderingMode
        self.source = source
    }

    public static let `default` = MarkdownEditorConfiguration()

    /// The background for the current rendering mode; nil means the platform default.
    public var activeBackground: PlatformColor? {
        renderingMode == .source ? (source.background ?? theme.background) : theme.background
    }
}

// MARK: - Rendering mode

/// How the editor shows markdown.
public enum RenderingMode: String, Sendable, CaseIterable {
    /// Markers hide away from the caret; images, tables, LaTeX, link cards
    /// and frontmatter render.
    case formatted
    /// Every character as typed, in a monospaced font, with the markdown
    /// syntax highlighted. Nothing renders.
    case source
}

/// Font and colors of `.source` mode. Revealed frontmatter in `.formatted`
/// mode uses the key color too.
public struct SourceModeStyle: Sendable {
    /// PostScript name of the font; nil uses the system monospaced font.
    public var fontName: String?
    /// Size relative to the editor's font size (monospaced faces run large).
    public var fontScale: CGFloat
    /// Headings (with their `#`s) and list / quote markers; nil uses the theme's link color.
    public var headingColor: PlatformColor?
    /// Inline code and fences.
    public var codeColor: PlatformColor
    /// Frontmatter keys.
    public var keyColor: PlatformColor
    /// `{…}` attribute blocks.
    public var attributeColor: PlatformColor
    /// Plain text. nil: the theme's body text.
    public var textColor: PlatformColor?
    /// Syntax markers (`**`, `[`, `](`, `|`, fences…). nil: the theme's muted text.
    public var markerColor: PlatformColor?
    /// Emphasis / strong text. nil: unchanged text color (just the font trait).
    public var emphasisColor: PlatformColor?
    /// Link and image text. nil: the theme's link color.
    public var linkColor: PlatformColor?
    /// Link and image destinations. nil: the theme's muted text.
    public var urlColor: PlatformColor?
    /// List and quote markers. nil: ``headingColor`` (or the theme's link color).
    public var listMarkerColor: PlatformColor?
    /// Background in source mode. nil: the theme's background.
    public var background: PlatformColor?

    public init(
        fontName: String? = nil,
        fontScale: CGFloat = 0.92,
        headingColor: PlatformColor? = nil,
        codeColor: PlatformColor = .systemPink,
        keyColor: PlatformColor = .systemOrange,
        attributeColor: PlatformColor = .systemPurple,
        textColor: PlatformColor? = nil,
        markerColor: PlatformColor? = nil,
        emphasisColor: PlatformColor? = nil,
        linkColor: PlatformColor? = nil,
        urlColor: PlatformColor? = nil,
        listMarkerColor: PlatformColor? = nil,
        background: PlatformColor? = nil
    ) {
        self.fontName = fontName
        self.fontScale = fontScale
        self.headingColor = headingColor
        self.codeColor = codeColor
        self.keyColor = keyColor
        self.attributeColor = attributeColor
        self.textColor = textColor
        self.markerColor = markerColor
        self.emphasisColor = emphasisColor
        self.linkColor = linkColor
        self.urlColor = urlColor
        self.listMarkerColor = listMarkerColor
        self.background = background
    }

    public static let `default` = SourceModeStyle()

    /// The source font for an editor font size of `size`.
    func font(size: CGFloat) -> PlatformFont {
        let scaled = (size * fontScale).rounded()
        if let fontName { return PlatformFont.md(named: fontName, size: scaled) }
        return PlatformFont.monospacedSystemFont(ofSize: scaled, weight: .regular)
    }
}

// MARK: - Spell checking

/// Initial state for the three "Spelling and Grammar" toggles. Only consulted
/// at `makeNSView` time; afterwards the user's context-menu choices take
/// precedence and are surfaced via ``NativeTextViewWrapper/onSpellCheckingPolicyChanged``.
public struct SpellCheckingPolicy: Sendable {
    /// Mirrors `NSTextView.isContinuousSpellCheckingEnabled`.
    public var continuousSpellChecking: Bool
    /// Mirrors `NSTextView.isGrammarCheckingEnabled`.
    public var grammarChecking: Bool
    /// Mirrors `NSTextView.isAutomaticSpellingCorrectionEnabled`.
    public var automaticSpellingCorrection: Bool

    public init(
        continuousSpellChecking: Bool = true,
        grammarChecking: Bool = true,
        automaticSpellingCorrection: Bool = true
    ) {
        self.continuousSpellChecking = continuousSpellChecking
        self.grammarChecking = grammarChecking
        self.automaticSpellingCorrection = automaticSpellingCorrection
    }

    public static let `default` = SpellCheckingPolicy()
}

// MARK: - Scroll bars

/// Scroll bar visibility. Default: vertical only, autohide on.
public struct ScrollersPolicy: Sendable {
    public var hasVerticalScroller: Bool
    public var hasHorizontalScroller: Bool
    public var autohidesScrollers: Bool

    public init(
        hasVerticalScroller: Bool = true,
        hasHorizontalScroller: Bool = false,
        autohidesScrollers: Bool = true
    ) {
        self.hasVerticalScroller = hasVerticalScroller
        self.hasHorizontalScroller = hasHorizontalScroller
        self.autohidesScrollers = autohidesScrollers
    }

    public static let `default` = ScrollersPolicy()
    /// No scrollers (use with a custom scroll overlay).
    public static let hidden = ScrollersPolicy(hasVerticalScroller: false, hasHorizontalScroller: false)
    /// Vertical only — same as `.default`.
    public static let vertical = ScrollersPolicy(hasVerticalScroller: true, hasHorizontalScroller: false)
    /// Both axes (code-heavy / wide content).
    public static let both = ScrollersPolicy(hasVerticalScroller: true, hasHorizontalScroller: true)
    /// Vertical, no auto-hide.
    public static let alwaysVisible = ScrollersPolicy(hasVerticalScroller: true, autohidesScrollers: false)
}

// MARK: - Text insets

/// Margins inside the text view (`NSTextView.textContainerInset`). Scroll bar stays at the outer edge.
public struct TextInsets: Sendable {
    public var horizontal: CGFloat
    public var vertical: CGFloat

    public init(horizontal: CGFloat = 0, vertical: CGFloat = 0) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let `default` = TextInsets()
}

// MARK: - Marker visibility

/// How Markdown syntax markers (e.g. `**`, `*`, `$`) are visualized when
/// the cursor is not inside the corresponding token.
///
/// The engine's default approach is to keep markers in the text storage but
/// shrink them to a near-zero font size (`hiddenMarkerFontSize`). This avoids
/// any range translation between displayed and stored text — cursor movement,
/// find/replace, selection, and copy/paste all stay trivially correct.
/// The trade-off is a sub-pixel residue at extreme zoom levels.
public struct MarkerStyle: Sendable {
    /// Font size used for "hidden" inline markers. Effectively invisible at
    /// normal zoom while keeping displayed-range == stored-range.
    public var hiddenMarkerFontSize: CGFloat
    /// Alpha applied to inline-code's secondary marker color.
    public var inlineCodeMarkerAlpha: CGFloat
    /// Alpha applied to non-focused find matches when in-document search
    /// highlights are visible. The focused match is drawn at full opacity.
    public var findMatchHighlightAlpha: CGFloat

    public init(
        hiddenMarkerFontSize: CGFloat = 0.1,
        inlineCodeMarkerAlpha: CGFloat = 0.5,
        findMatchHighlightAlpha: CGFloat = 0.65
    ) {
        self.hiddenMarkerFontSize = hiddenMarkerFontSize
        self.inlineCodeMarkerAlpha = inlineCodeMarkerAlpha
        self.findMatchHighlightAlpha = findMatchHighlightAlpha
    }

    public static let `default` = MarkerStyle()
}

// MARK: - Code blocks

/// Styling for fenced code blocks (```language ... ```).
public struct CodeBlockStyle: Sendable {
    /// Code-block font size as a fraction of the document base font size.
    public var fontSizeScale: CGFloat
    /// Vertical paragraph spacing applied above and below the code block.
    public var paragraphSpacing: CGFloat
    /// Left/right indent (in points) so code blocks don't run into the gutter.
    public var horizontalIndent: CGFloat

    public init(
        fontSizeScale: CGFloat = 0.85,
        paragraphSpacing: CGFloat = 2.0,
        horizontalIndent: CGFloat = 12.0
    ) {
        self.fontSizeScale = fontSizeScale
        self.paragraphSpacing = paragraphSpacing
        self.horizontalIndent = horizontalIndent
    }

    public static let `default` = CodeBlockStyle()
}

// MARK: - Inline code

/// Styling for inline `` `code` `` spans.
public struct InlineCodeStyle: Sendable {
    /// Inline-code reuses the code block font size scale by default.
    public var fontSizeScale: CGFloat

    public init(fontSizeScale: CGFloat = 0.85) {
        self.fontSizeScale = fontSizeScale
    }

    public static let `default` = InlineCodeStyle()
}

// MARK: - Lists

/// Behavior toggles and metrics for ordered / unordered list editing.
public struct ListStyle: Sendable {
    /// Master switch for list-related editing helpers (auto-continue,
    /// auto-indent, marker conversion). When `false`, lists are still
    /// rendered, but typing-time conveniences are skipped.
    public var helpersEnabled: Bool
    /// Master switch for auto-closing pairs `()`, `{}`, `[]` while typing.
    public var autoClosePairsEnabled: Bool
    /// Indent (in points) that one nesting level adds to the list item.
    public var indentPerLevel: CGFloat
    /// Maximum nesting level reachable by pressing Tab inside a list.
    public var maximumNestingLevel: Int
    /// Extra line height added on top of the default to give list items room.
    public var extraLineHeight: CGFloat

    public init(
        helpersEnabled: Bool = true,
        autoClosePairsEnabled: Bool = true,
        indentPerLevel: CGFloat = 27.5,
        maximumNestingLevel: Int = 3,
        extraLineHeight: CGFloat = 2
    ) {
        self.helpersEnabled = helpersEnabled
        self.autoClosePairsEnabled = autoClosePairsEnabled
        self.indentPerLevel = indentPerLevel
        self.maximumNestingLevel = maximumNestingLevel
        self.extraLineHeight = extraLineHeight
    }

    public static let `default` = ListStyle()
}

// MARK: - Headings

/// Per-level heading metrics. Defaults follow the historical Nodes ratios,
/// which are loosely based on browser default heading sizes.
public struct HeadingStyle: Sendable {
    /// Font-size multiplier per heading level (1...6).
    public var fontMultipliers: [CGFloat]
    /// Top spacing in `em` units per heading level (1...6).
    public var topSpacingEm: [CGFloat]

    public init(
        fontMultipliers: [CGFloat] = [2.0, 1.5, 1.17, 1.0, 0.83, 0.67],
        topSpacingEm: [CGFloat] = [0.35, 0.30, 0.25, 0.20, 0.15, 0.10]
    ) {
        self.fontMultipliers = fontMultipliers
        self.topSpacingEm = topSpacingEm
    }

    public func fontMultiplier(for level: Int) -> CGFloat {
        let index = max(1, min(level, fontMultipliers.count)) - 1
        return fontMultipliers[index]
    }

    public func topSpacingEm(for level: Int) -> CGFloat {
        let index = max(1, min(level, topSpacingEm.count)) - 1
        return topSpacingEm[index]
    }

    public static let `default` = HeadingStyle()
}

// MARK: - Images

/// Sizing and spacing rules for block images (`![alt](source)` on its own line).
public struct ImageStyle: Sendable {
    /// Minimum allowed display width (points) for a block image.
    public var minimumWidth: CGFloat
    /// Fallback maximum width if no usable text container width is available.
    public var fallbackMaxWidth: CGFloat
    /// Sanity bound — container widths above this are treated as invalid.
    public var unreasonableMaxWidth: CGFloat
    /// Vertical paragraph spacing above/below the image paragraph.
    public var paragraphSpacing: CGFloat
    /// Gap between the source line and the rendered image (visibleSource mode).
    public var imageGap: CGFloat
    /// Maximum widths for `{.small}`, `{.medium}` and `{.large}`.
    public var smallWidth: CGFloat
    public var mediumWidth: CGFloat
    public var largeWidth: CGFloat

    public init(
        minimumWidth: CGFloat = 50,
        fallbackMaxWidth: CGFloat = 650,
        unreasonableMaxWidth: CGFloat = 1_000_000,
        paragraphSpacing: CGFloat = 8,
        imageGap: CGFloat = 8,
        smallWidth: CGFloat = 160,
        mediumWidth: CGFloat = 320,
        largeWidth: CGFloat = 640
    ) {
        self.minimumWidth = minimumWidth
        self.fallbackMaxWidth = fallbackMaxWidth
        self.unreasonableMaxWidth = unreasonableMaxWidth
        self.paragraphSpacing = paragraphSpacing
        self.imageGap = imageGap
        self.smallWidth = smallWidth
        self.mediumWidth = mediumWidth
        self.largeWidth = largeWidth
    }

    public static let `default` = ImageStyle()

    /// The size an image is drawn at.
    ///
    /// - `width=` / `height=` (or the alt-text `widthHint`) set the size in
    ///   points; with both, the image fits inside that box.
    /// - `.icon` is line height; `.small` / `.medium` / `.large` cap the
    ///   width (never upscaling); `.full` fills the column.
    /// - With no size the image keeps its natural width.
    ///
    /// The aspect ratio is always kept and the width never exceeds `maxWidth`.
    public func displaySize(
        natural: CGSize,
        attributes: MarkdownAttributes,
        widthHint: CGFloat? = nil,
        maxWidth: CGFloat,
        lineHeight: CGFloat
    ) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return natural }
        let aspect = natural.height / natural.width
        var width: CGFloat
        let explicitWidth = attributes.width ?? (attributes.size == nil ? widthHint : nil)
        switch (explicitWidth, attributes.height) {
        case let (w?, h?): width = min(w, h / aspect)
        case let (w?, nil): width = w
        case let (nil, h?): width = h / aspect
        case (nil, nil):
            switch attributes.size {
            case .icon: width = lineHeight / aspect
            case .small: width = min(natural.width, smallWidth)
            case .medium: width = min(natural.width, mediumWidth)
            case .large: width = min(natural.width, largeWidth)
            case .full: width = maxWidth
            case nil: width = max(natural.width, minimumWidth)
            }
        }
        width = min(width, maxWidth)
        return CGSize(width: width, height: width * aspect)
    }

    /// The Obsidian width hint in alt text: `![photo|200](…)` or
    /// `![|200x100](…)` gives 200.
    public static func widthHint(alt: String) -> CGFloat? {
        guard let bar = alt.lastIndex(of: "|") else { return nil }
        let spec = alt[alt.index(after: bar)...].trimmingCharacters(in: .whitespaces)
        let widthPart = spec.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let n = Int(widthPart), n > 0 else { return nil }
        return CGFloat(n)
    }
}

// MARK: - LaTeX

/// Vertical spacing for block-LaTeX `$$...$$` paragraphs.
public struct BlockLatexStyle: Sendable {
    /// Top spacing for $$...$$ block paragraphs.
    public var paragraphSpacingBefore: CGFloat
    /// Bottom spacing for $$...$$ block paragraphs.
    public var paragraphSpacing: CGFloat
    /// Extra bottom padding added to single-letter formulas to avoid clipping.
    public var singleLetterPaddingBottom: CGFloat

    public init(
        paragraphSpacingBefore: CGFloat = 16,
        paragraphSpacing: CGFloat = 20,
        singleLetterPaddingBottom: CGFloat = 1.0
    ) {
        self.paragraphSpacingBefore = paragraphSpacingBefore
        self.paragraphSpacing = paragraphSpacing
        self.singleLetterPaddingBottom = singleLetterPaddingBottom
    }

    public static let `default` = BlockLatexStyle()
}

/// Reserved for future inline-LaTeX (`$...$`) tuning. Currently has no
/// effect; inline LaTeX inherits font size from the surrounding context.
public struct InlineLatexStyle: Sendable {
    /// Reserved for future inline-LaTeX tuning — currently the engine inherits
    /// font size from the surrounding heading context.
    public var placeholder: Void

    public init() { self.placeholder = () }

    public static let `default` = InlineLatexStyle()
}

// MARK: - Task checkboxes

/// Glyph sizing and spacing for `- [ ]` / `- [x]` task checkboxes.
public struct CheckboxStyle: Sendable {
    /// Minimum extra spacing (points) inserted after an unchecked checkbox to
    /// optically center the rendered glyph.
    public var minimumExtraSpacing: CGFloat
    /// Additional spacing as a fraction of the surrounding font's point size.
    public var extraSpacingPerFontPointFraction: CGFloat
    /// Checkbox glyph size as a fraction of the line's font height.
    public var sizeFromFontHeightFactor: CGFloat
    /// Checkbox glyph size as a fraction of the `[ ]` marker width.
    public var sizeFromMarkerWidthFactor: CGFloat
    /// Inset applied inside the checkbox bounding box before drawing the icon.
    public var iconInsetFraction: CGFloat
    /// Square boxes (default) or round ones, as in Apple Notes.
    public var shape: Shape = .square
    /// Checking an item moves it below the unchecked ones of its checklist.
    public var movesCheckedToBottom = false

    public enum Shape: String, Sendable, CaseIterable { case square, circle }

    public init(
        minimumExtraSpacing: CGFloat = 2.0,
        extraSpacingPerFontPointFraction: CGFloat = 0.18,
        sizeFromFontHeightFactor: CGFloat = 1.2,
        sizeFromMarkerWidthFactor: CGFloat = 1.2,
        iconInsetFraction: CGFloat = 0.01
    ) {
        self.minimumExtraSpacing = minimumExtraSpacing
        self.extraSpacingPerFontPointFraction = extraSpacingPerFontPointFraction
        self.sizeFromFontHeightFactor = sizeFromFontHeightFactor
        self.sizeFromMarkerWidthFactor = sizeFromMarkerWidthFactor
        self.iconInsetFraction = iconInsetFraction
    }

    public static let `default` = CheckboxStyle()
}

// MARK: - Links

/// Foreground alpha values applied to link content in different states.
public struct LinkStyle: Sendable {
    /// Foreground alpha for the visible label of an active markdown link.
    public var activeLinkAlpha: CGFloat
    /// Foreground alpha applied to "incomplete" link content (e.g. `[text]`
    /// without a target).
    public var incompleteLinkAlpha: CGFloat

    public init(activeLinkAlpha: CGFloat = 0.55, incompleteLinkAlpha: CGFloat = 0.7) {
        self.activeLinkAlpha = activeLinkAlpha
        self.incompleteLinkAlpha = incompleteLinkAlpha
    }

    public static let `default` = LinkStyle()
}

// MARK: - Paragraphs

/// Default paragraph spacing and line height applied to body text.
public struct ParagraphStyle: Sendable {
    /// Extra paragraph spacing as a fraction of the document's default line height.
    public var spacingFactor: CGFloat
    /// Extra height (points) added to the default paragraph line height.
    public var lineHeightExtraSpacing: CGFloat

    public init(spacingFactor: CGFloat = 0.3, lineHeightExtraSpacing: CGFloat = 2) {
        self.spacingFactor = spacingFactor
        self.lineHeightExtraSpacing = lineHeightExtraSpacing
    }

    public static let `default` = ParagraphStyle()
}

// MARK: - Bottom overscroll

/// Controls the empty space below the last line so that typing at the bottom
/// of a long document remains comfortable instead of pinning to the viewport
/// bottom edge.
public struct OverscrollPolicy: Sendable {
    /// Desired overscroll as a fraction of the visible viewport height.
    public var percent: CGFloat
    /// Hard upper bound for the overscroll in points.
    public var maxPoints: CGFloat
    /// Hard lower bound for the overscroll in points.
    public var minPoints: CGFloat
    /// Fraction of the viewport above which overscroll starts ramping up.
    public var activationStartFraction: CGFloat
    /// Fraction of the viewport over which overscroll fully ramps in.
    public var activationRangeFraction: CGFloat

    public init(
        percent: CGFloat = 0.5,
        maxPoints: CGFloat = 450,
        minPoints: CGFloat = 40,
        activationStartFraction: CGFloat = 0.15,
        activationRangeFraction: CGFloat = 0.85
    ) {
        self.percent = percent
        self.maxPoints = maxPoints
        self.minPoints = minPoints
        self.activationStartFraction = activationStartFraction
        self.activationRangeFraction = activationRangeFraction
    }

    public static let `default` = OverscrollPolicy()
}

// MARK: - Drag selection

/// Tuning for the auto-scroll boost that engages while the user drags a
/// selection past the visible viewport edges.
public struct DragSelectionPolicy: Sendable {
    /// Movement threshold (points) before the auto-scroll boost engages.
    public var movementThreshold: CGFloat
    /// Distance from the window edge that triggers the boost.
    public var edgeTriggerDistance: CGFloat
    /// Pixels per tick scrolled while the boost is active.
    public var scrollStepPerTick: CGFloat
    /// Boost timer frequency (ticks per second).
    public var ticksPerSecond: Double

    public init(
        movementThreshold: CGFloat = 5.0,
        edgeTriggerDistance: CGFloat = 5.0,
        scrollStepPerTick: CGFloat = 12.0,
        ticksPerSecond: Double = 60.0
    ) {
        self.movementThreshold = movementThreshold
        self.edgeTriggerDistance = edgeTriggerDistance
        self.scrollStepPerTick = scrollStepPerTick
        self.ticksPerSecond = ticksPerSecond
    }

    public static let `default` = DragSelectionPolicy()
}

// MARK: - Safe-area insets

/// Reserves space on the scroll view for system overlays (e.g. a translucent toolbar to scroll underneath). Maps to `NSScrollView.contentInsets`; scroll bar follows the inset.
public struct SafeAreaInsets: Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var trailing: CGFloat
    public var bottom: CGFloat

    public init(
        top: CGFloat = 0,
        leading: CGFloat = 0,
        trailing: CGFloat = 0,
        bottom: CGFloat = 0
    ) {
        self.top = top
        self.leading = leading
        self.trailing = trailing
        self.bottom = bottom
    }

    public static let `default` = SafeAreaInsets()
}
