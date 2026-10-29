# Changelog

All notable changes to swift-markdown-engine are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `MarkdownEditorController`: pass one to `NativeTextViewWrapper(controller:)`
  to address that editor from outside: `insertText(_:actionName:)` replaces
  the selection as one undoable edit, `selectedRange`, `reveal(_:)` (select
  and scroll to a range), `focus()`. Unlike the
  notification bus it targets a single editor.
- Link preview cards: a standalone `[text](url){.preview}` (or any size
  attribute) renders as a card (`.small`, `.medium`, `.large`, `.full`;
  `width=` / `height=`; aligned like images), from metadata supplied by the
  new `LinkPreviewProvider` service (`MarkdownEditorServices.linkPreviews`).
  `.icon` links get an inline icon; `.unavailable` targets a badge;
  `.loading` cards fall back to the link text. `LinkPreviewStyle` holds the
  card sizes. Both platforms restyle when a provider's fingerprint changes
  (iOS previously ignored `ImageProvider` fingerprint changes too).
- `{…}` attributes after images and links (`![](a.png){.small .center}`,
  `[Doc](a.pdf){.preview}`), parsed into `MarkdownAttributes` and hidden
  like other markers when the caret is elsewhere. Images honour `.icon`
  (inline, line height), `.small` / `.medium` / `.large` / `.full`,
  `width=` / `height=`, `.left` / `.center` / `.right`, and the Obsidian
  `![alt|200](…)` width hint. `ImageRequest` gains `attributes`;
  `ImageStyle` gains `smallWidth` / `mediumWidth` / `largeWidth` and
  `displaySize(...)`. On macOS, image paragraphs restyle when the column
  width changes.
- File drops: `NativeTextViewWrapper(onDropFiles:)` (macOS and iOS) passes
  dropped files to the embedder, which stores them and returns the markdown
  to insert at the drop point (one undoable edit). `DroppedFile` describes
  each file; `markdownLink(to:)` builds an image or file link.
- WYSIWYG tables (macOS and iOS): every GFM table is an editable grid. Click a cell
  to edit its raw inline markdown; Tab / Shift-Tab / Return / arrows move
  between cells (Tab past the last cell or Return in the last row adds a
  row), Esc discards. The context menu inserts, deletes, and moves rows and
  columns, sets alignment, and offers "Edit as Markdown" for the raw pipe
  source. Each committed change rewrites the table as normalized GFM in one
  undoable edit. Backed by the new `MarkdownTable` model (escape-aware
  parse / serialize, structural edits).
  On iOS: tap to edit, long-press for the context menu, hardware-keyboard
  Tab / arrows / Esc, Return moves down (`TableGridUIView`).
- iOS / iPadOS support: the parser, styler, and renderer build for UIKit via
  platform aliases (`PlatformFont`, `PlatformColor`, ...), and
  `NativeTextViewWrapper` has a UIKit implementation (`TextView/UIKit/`).
  Demo app in `Demo/iOS` (generate with `xcodegen`).
- Scroll-away header: `NativeTextViewWrapper` gains `header: AnyView?`,
  `headerCollapsedHeight: CGFloat`, and `headerExpanded: Bool`. The engine
  hosts the supplied SwiftUI view above the document body, scrolling with
  it; collapsing animates the reserved band down to `headerCollapsedHeight`
  (the top row stays visible, lower rows clip away). The hosted content
  refreshes on every SwiftUI update and stays fully interactive. Composes
  with `readingWidth`. See the README's *Scrolling Header* section.

### Removed
- Wiki-links (`[[Name]]`, `[[Name|id]]`) and wiki embeds (`![[Name]]`) are no
  longer parsed; they render as plain text. Removed with them:
  `WikiLinkResolver`, `WikiLinkService`, `InlineSelectionState`,
  `InlineReplacementRequest`, and the wrapper parameters `isWikiLinkActive`,
  `pendingInlineReplacement`, `onCaretRectChange`, `onInlineSelectionChange`.

### Changed
- UIKit `NativeTextViewWrapper.init` takes `onDropFiles:` before
  `onLinkClick:`, matching AppKit, so one call site serves both platforms.
- iOS programmatic edits (list continuation, checkbox taps, table writes)
  go straight to the text storage with their own undo: `replace(_:withText:)`
  applied smart dashes, turning a table's `---` into `—`.
- System fonts are no longer looked up by their private names
  (`.SFUI-Regular`), which UIKit resolved to Times after a restyle.
- A table no longer reveals its raw source just because the caret is
  inside it (macOS); arrowing into a table focuses its grid instead.
- Undo / redo now re-sync the `text` binding and restyle; AppKit applies
  them without posting `NSText.didChangeNotification`.
- `EmbeddedImageProvider` / `EmbeddedImageRequest(name:)` are now
  `ImageProvider` / `ImageRequest(source:)`; `configuration.imageEmbed` is
  `configuration.images` (`ImageStyle`).
- `onLinkClick` receives the link destination for every markdown link; when
  it is nil, AppKit opens the URL itself.
- The scroll view's `documentView` is now always an engine-internal
  container view (hosting the text view, the optional scroll-away header,
  and the reading column's breakout overlays) rather than sometimes the
  `NSTextView` itself. Embedders that reached into
  `scrollView.documentView` expecting an `NSTextView` must adapt — the
  document view's class was never API.
- **Breaking**: The editor's enclosing scroll view no longer applies a
  hard-coded `top: 55.4` content inset. The default is now `0` on every
  edge, matching the most common embedding case where the editor fills
  its container exactly. Embedders that previously relied on the engine
  reserving header space (e.g. for a translucent toolbar) must opt in
  explicitly:

  ```swift
  var config = MarkdownEditorConfiguration.default
  config.safeAreaInsets = SafeAreaInsets(top: 55.4)
  ```

### Added
- `SafeAreaInsets` struct exposing `top` / `leading` / `trailing` / `bottom`
  inset knobs for the editor's enclosing scroll view, configurable via
  `MarkdownEditorConfiguration.safeAreaInsets`.
- `MarkdownASTStyler` now stamps `.spellingState: 0` on fenced code blocks
  and inline `` `code` `` spans, completing the engine's existing
  spell-check suppression convention (links, wiki-links, LaTeX, and tables
  already carry the same attribute). The system spell-checker no longer
  underlines tokens inside code regions even when continuous spell
  checking is enabled.

### Fixed
- macOS: an editor showing the top of its document stays at the top when its
  viewport resizes (a bar appearing above it no longer hides the first lines),
  and `safeAreaInsets` changes after creation are applied.
- Link destinations without `://` (relative paths, `mailto:`, `#anchors`)
  were rewritten to `https://…` before reaching `onLinkClick`.
- `NativeTextViewWrapper` keeps links clickable and text selectable
  when `isEditable: false`; `isSelectable` is no longer coupled to
  `isEditable`. (#31)
- `NativeTextViewWrapper` now applies its initial styling pass even when
  the bound text starts at its final value (e.g. supplied as a SwiftUI
  `@State` initializer). Previously the editor would render the raw
  Markdown source until the user clicked into the document, because the
  coordinator's `lastSyncedText` already matched the bound text at first
  `updateNSView`. The early-return now also requires `didInitialFormatting`
  to be true, which only flips after the first styling pass completes.

### Added
- Initial public API surface:
  - `NativeTextViewWrapper` — SwiftUI bridge for the AppKit-backed editor
  - `MarkdownEditorConfiguration` — every spacing / sizing / behavior knob
  - `MarkdownEditorTheme` — color palette, defaults to system colors
  - `MarkdownEditorServices` — container for the four service protocols
  - Service protocols: `WikiLinkResolver`, `EmbeddedImageProvider`,
    `SyntaxHighlighter`, `LatexRenderer`
  - No-op default implementations: `NoOpWikiLinkResolver`,
    `NoOpEmbeddedImageProvider`, `PlainTextSyntaxHighlighter`,
    `NoOpLatexRenderer`
  - `WikiLinkService` — bidirectional storage / display roundtrip helper
  - `PasteboardImageReader` — pasteboard image inspection helpers
  - Selection / replacement value types: `WikiLinkSelection`,
    `InlineSelectionState`, `InlineReplacementRequest`, `CodeBlockSelection`
  - `CodeBlockButton` — drop-in copy button overlay
- DocC documentation catalog with landing page and topic groups
- Triple-slash documentation comments on the full public API surface

[Unreleased]: https://github.com/nodes-app/swift-markdown-engine/compare/HEAD
