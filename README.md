<h1 align="center">MarkdownKit</h1>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white" alt="Swift 5.9+" /></a>
  <img src="https://img.shields.io/badge/Platforms-macOS%2014+%20%7C%20iOS%2017+-lightgrey" alt="Platforms: macOS 14+, iOS 17+" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-yellow.svg" alt="License: Apache 2.0" /></a>
  <a href="https://github.com/emdzej/markdownkit/actions/workflows/ci.yml"><img src="https://github.com/emdzej/markdownkit/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
</p>

A native Markdown editor for macOS (AppKit) and iOS / iPadOS (UIKit), built on TextKit 2 and bridged to
SwiftUI. Formatting renders in place and the markers come back on the line you're editing, so the
document reads like a rich-text page and stays plain CommonMark + GFM on disk. The bytes are never
rewritten behind your back.

MarkdownKit is the editor of [Notes my Way](https://notesmyway.emdzej.pl). It started as a fork of
[swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) and has since grown into a
separate engine, with iOS support, editable tables with formulas and a formatting API (see
[Origins](#origins)).

## Features

- **Blend editing**: headings, emphasis, lists, quotes, code, links and rules are styled in place; the
  markers fold away off the caret's line and come back on it
- **Markdown source mode**: every character visible, monospaced, with syntax colours (`renderingMode = .source`)
- **WYSIWYG tables** on both platforms: a grid with cell editing, Tab / Return navigation, hover markers to add
  rows and columns, row and column handle menus, drag-to-resize columns (`{cols="…"}` after the table) and
  "Edit as Markdown"; the file stays a pipe table
- **Table formulas**: `[?](#SUM(B1:B4))` cells computed live, with the syntax and functions of
  [vitepress-plugin-markdownformula](https://github.com/emdzej/vitepress-plugin-markdownformula)
- **Frontmatter** shown as chips in formatted mode
- **Images** with `{…}` attributes for size and alignment (`{.small}`, `{.icon}`, `{width=320 .center}`); the
  embedder supplies the bytes
- **Link preview cards**: `[text](url){.preview}` in four sizes, from metadata the embedder supplies
- **Checklists**: tappable boxes (round or square, sized for touch on iOS), check / uncheck all, move checked
  items to the bottom
- **Formatting API**: `MarkdownEditorController` toggles inline styles, sets block styles, indents, inserts
  tables and edits table cells, for toolbars, menus and keyboard bars
- **Find and replace**: the macOS find bar and the iOS find interaction
- **HTML export** (`MarkdownHTML`): the same parse as the editor, for printing and PDF
- **Theming**: colours for text, headings, links, code, quotes, rules, tables, selection, caret and chips,
  heading fonts, and the source view's colours
- **Code blocks** with pluggable syntax highlighting, and **LaTeX** (block and inline) with a pluggable renderer
- **File drops**: dropped files go to an `onDropFiles` hook that stores them and returns the link to insert
- **Reading column**, **scroll-away header**, comfortable bottom overscroll, spelling and grammar with
  code / LaTeX / link suppression, and Writing Tools on macOS 15.1+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/emdzej/markdownkit", branch: "main")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "MarkdownEngine", package: "markdownkit"),
        ]
    )
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repo URL.

The package ships three library products (they keep their `MarkdownEngine` names, so they don't clash
with other packages called MarkdownKit). Add only what you need:

| Product | Use when |
|---|---|
| `MarkdownEngine` | You want the editor only. No external dependencies. |
| `MarkdownEngineCodeBlocks` | You want code blocks with a background, a monospaced font and syntax highlighting without writing your own bridge. Pulls in [HighlighterSwift](https://github.com/smittytone/HighlighterSwift). See [Code Blocks](#code-blocks). |
| `MarkdownEngineLatex` | You want LaTeX rendering without writing your own bridge. Pulls in [SwiftMath](https://github.com/mgriebling/SwiftMath). See [LaTeX Rendering](#latex-rendering). |

## Quick Start

```swift
import SwiftUI
import MarkdownEngine

struct EditorScreen: View {
    @State private var text: String = "# Hello, *world*"
    @State private var controller = MarkdownEditorController()

    var body: some View {
        NativeTextViewWrapper(text: $text, controller: controller)
            .toolbar {
                Button("Bold") { controller.toggle(.bold) }
                Button("Checklist") { controller.setBlockStyle(.task) }
            }
    }
}
```

The same `NativeTextViewWrapper` works on macOS and iOS. When several editors are on screen, pass a
stable `documentId:` to each so undo history stays scoped to its document.

## Customization

### Service Protocols

The engine talks to your app through three service protocols, each with
a no-op default so you only implement what you actually need:

| Protocol | What you supply | Ready-made bridge / suggested library |
|---|---|---|
| `ImageProvider` | Load the image for `![alt](source)` | (your asset store) |
| `LinkPreviewProvider` | Metadata for `[text](url){.preview}` cards | LinkPresentation / QuickLookThumbnailing |
| `SyntaxHighlighter` | Highlight code blocks for a given language | **`HighlighterSwiftBridge`** ([recommended](#code-blocks)) — built on [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) |
| `LatexRenderer` | Render a LaTeX string to an `NSImage` | **`SwiftMathBridge`** ([recommended](#latex-rendering)) — built on [SwiftMath](https://github.com/mgriebling/SwiftMath) |

Implement what you need and pass it through `MarkdownEditorServices`:

```swift
struct VaultImages: ImageProvider {
    let root: URL
    func image(for request: ImageRequest) -> PlatformImage? {
        PlatformImage(contentsOfFile: root.appending(path: request.source).path)
    }
    func fingerprint() -> AnyHashable { root }
}

configuration.services = MarkdownEditorServices(
    images: VaultImages(root: vaultURL)
    // syntaxHighlighter, latex omitted → no-op defaults
)
```

Each protocol and its no-op default are documented in DocC.

### Code Blocks

**Recommended path: depend on the `MarkdownEngineCodeBlocks` product
and use the bundled `HighlighterSwiftBridge`.** Rolling your own
`SyntaxHighlighter` has subtle footguns the bridge already handles —
line-height metrics across light/dark themes, appearance-change
observation, layout-pass timing, font name extraction from the theme,
and CSS-theme-derived background colors. Use the bundle unless you
specifically need a non-HighlighterSwift library.

```swift
import MarkdownEngineCodeBlocks

var configuration = MarkdownEditorConfiguration.default
configuration.services = MarkdownEditorServices(
    syntaxHighlighter: HighlighterSwiftBridge()
)
```

The bridge auto-switches between `atom-one-light` and `atom-one-dark`
with system appearance. Different theme names or a pinned single theme
are configurable via init params — see DocC.

Need a different highlighter library entirely? Implement
`SyntaxHighlighter` yourself (see [Service Protocols](#service-protocols)
above for the declaration) and reference the bundled bridge in
`Sources/MarkdownEngineCodeBlocks/` as a working example.

### LaTeX Rendering

**Recommended path: depend on the `MarkdownEngineLatex` product and use
the bundled `SwiftMathBridge`.** Hand-rolling a `LatexRenderer` has
real footguns the bridge already handles — appearance-aware text color,
zero-sized output guards (`lockFocus` crashes on 0×0 images),
window-vs-NSApp appearance distinction, single-letter padding, and an
internal cache keyed by (latex, font size, appearance, theme color).

```swift
import MarkdownEngineLatex

var configuration = MarkdownEditorConfiguration.default
configuration.services = MarkdownEditorServices(
    latex: SwiftMathBridge()
)
```

The bridge uses the Latin Modern math font and tints formulas with
`MarkdownEditorTheme.latexLightModeText` / `latexDarkModeText`. Pass
`singleLetterPaddingBottom:` to override the engine's matching default.

### Theming

Every color the editor puts on screen reads from `MarkdownEditorTheme`:

```swift
var theme = MarkdownEditorTheme.default
theme.bodyText = .labelColor
theme.findMatchHighlight = NSColor(named: "MyAccent")!

var configuration = MarkdownEditorConfiguration.default
configuration.theme = theme
```

Defaults map to `NSColor` dynamic system colors, so light/dark mode
keeps working without extra code.

### Tuning

`MarkdownEditorConfiguration` exposes every spacing / sizing / behavior
knob the engine has, grouped by concern:

```swift
var configuration = MarkdownEditorConfiguration.default
configuration.codeBlock.fontSizeScale = 0.9
configuration.headings.fontMultipliers = [2.4, 1.8, 1.4, 1.1, 0.9, 0.75]
configuration.overscroll.percent = 0.4
configuration.lists.helpersEnabled = false
configuration.safeAreaInsets = SafeAreaInsets(top: 56)   // headroom under a translucent toolbar
```

### Image and Link Attributes

A `{…}` block written directly after an image or link (Pandoc syntax:
`.class`, `#id`, `key=value`) is parsed into `MarkdownAttributes`, hidden
while the caret is elsewhere, and shown dimmed when the caret is on it.

```markdown
![](diagram.png){.small}          160 pt max width (.medium 320, .large 640)
![](photo.jpg){.full}             full column width
![](chart.png){width=320 .center} explicit points; .left / .center / .right
Built with ![](swift.png){.icon}  inline, at line height
![photo|200](photo.jpg)           Obsidian width hint, also honoured
[Spec](spec.pdf){.preview}        preview card, see below
```

Images keep their aspect ratio and never grow past the column; `.small`,
`.medium` and `.large` never upscale. The widths are in `ImageStyle`, and
`ImageRequest.attributes` lets your `ImageProvider` pick a suitably sized
thumbnail. Text that isn't valid attribute syntax, or a brace after a
space, stays ordinary text. `MarkdownAttributes.setSize(_:)` and
`markdown()` rewrite the block for a size menu.

### Link Preview Cards

A link on its own line with `{.preview}` or a size renders as a card:
`.small` is one line (icon, title, host), `.medium` (the default) adds a
thumbnail and description, `.large` / `.full` put a hero image on top.
With the caret on the link the markdown shows, with the card below it.
`{.icon}` puts the target's icon before the link text, anywhere in a
paragraph. Clicking a card goes to `onLinkClick` like any link.

The engine only draws. Supply the metadata with a `LinkPreviewProvider`
(LinkPresentation for web pages, QuickLook thumbnails for files, ...):

```swift
struct Previews: LinkPreviewProvider {
    let store: PreviewStore   // your fetcher + cache
    func preview(for request: LinkPreviewRequest) -> LinkPreview? {
        store.cached(request.destination) ?? { store.fetch(request.destination); return .loading }()
    }
    func fingerprint() -> AnyHashable { store.version }   // bump when a fetch finishes
}
configuration.services.linkPreviews = Previews(store: store)
```

Return `nil` to keep a plain link, `.loading` while fetching (the card shows
the link text and host), or `.unavailable` for a muted badge after the link.
Card widths are in `configuration.linkPreviews`. Link destinations reach
`onLinkClick` as written: relative paths and `mailto:` are no longer turned
into `https://` URLs.

### Dropping Files

Pass `onDropFiles` to accept files dragged onto the editor (Finder, Files,
Photos, Mail, …). Store them wherever your app keeps attachments and return
the markdown to insert at the drop point; `DroppedFile.markdownLink(to:)`
builds `![](…)` for images and `[name](…)` for everything else, with the path
percent-encoded. The engine inserts the result as one undoable edit. Return
`nil` to ignore the drop.

```swift
NativeTextViewWrapper(text: $text, onDropFiles: { files in
    var links: [String] = []
    for file in files {
        let target = attachmentsFolder.appending(path: file.name)
        try? FileManager.default.copyItem(at: file.url, to: target)
        links.append(file.markdownLink(to: "_attachments/\(file.name)"))
    }
    return links.joined(separator: "\n")
})
```

On iOS the `DroppedFile` URLs are temporary copies, deleted after the
handler returns — copy them, don't keep the URLs. Dragged text keeps the
system behaviour.

### Reading Column

Give long documents a fixed-width, centered column — and let wide GFM
tables break out of it to the full window width, Google-Docs-style:

```swift
var configuration = MarkdownEditorConfiguration.default
configuration.readingWidth = 650
```

- Text wraps at `readingWidth` and never re-wraps on window resize —
  only the column's position moves, which keeps live resize smooth.
- Tables wider than the column expand up to the full viewport width and
  scroll horizontally beyond that.
- Leave it `nil` (the default) and the editor fills its container
  edge-to-edge, exactly as before.

### Scrolling Header

Host a SwiftUI view above the document body that scrolls away with it —
document metadata, a property table, a contextual toolbar:

```swift
NativeTextViewWrapper(
    text: $text,
    header: AnyView(MyDocumentHeader(document: document)),
    headerCollapsedHeight: 40,
    headerExpanded: isHeaderExpanded
)
```

- The engine hosts the view in an `NSHostingView`, reserves its
  intrinsic height at the top of the scrolled content, and shifts the
  body below it. The header is a sibling of the text view, so it stays
  fully interactive (buttons, text fields, menus).
- `headerExpanded: false` collapses the band to `headerCollapsedHeight`:
  the top row stays visible while the rows below clip away. Toggling
  animates the reveal. Size your header so the content above
  `headerCollapsedHeight` is the part you want to keep visible.
- The hosted content refreshes on every SwiftUI update — bind your
  model into the header view as usual. Inject any required environment
  (`.environmentObject`, `.environment`) into the view *before* wrapping
  it in `AnyView`; the hosting view does not inherit your hierarchy's
  environment.
- The reserved band uses the view's **intrinsic** (ideal) height. Text
  that relies on wrapping at the editor's width can render taller than
  its ideal height and clip at the band's bottom — give wrapping
  content an explicit height (`.frame`/`.fixedSize`) or line limit.
- Composes with `readingWidth`: the header spans the full viewport
  width while the body keeps its centered column.
- An optional `placeholder: NSAttributedString?` renders ghost text at
  the first-line position while the document is empty — below the header
  band, tracking its reveal animation; the first keystroke hides it.
  Style it with the editor's body font so it lines up with the would-be
  first line.
- Pass `header: nil` (the default) and the editor renders exactly as
  before — the header path adds nothing to header-less editors.

The demo app's **Header** toolbar toggle shows the full behavior.


## Demo

Runnable demos live in [`Demo/`](Demo): `MarkdownEngineDemo.xcodeproj` for macOS, and `Demo/iOS` for
iPhone and iPad (run `xcodegen` there first). Both reference the package by a local path, so engine edits
rebuild into the demo on the next run.

## Requirements

- macOS 14 or later (15.1+ for Writing Tools), iOS / iPadOS 17 or later
- Swift 5.9 / Xcode 15 or later; CI builds with Xcode 26

The API is pre-1.0 and changes as Notes my Way needs it. Pin a commit if you depend on it.

## Contributing

Bug reports, ideas and pull requests are welcome.

- [ARCHITECTURE.md](ARCHITECTURE.md): the codemap and the parse → style → render pipeline
- [CONTRIBUTING.md](CONTRIBUTING.md): setup, tests and design constraints

## Origins

MarkdownKit began as a fork of [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)
by Luca Chen and contributors, the editor of [Nodes](https://apps.apple.com/app/id6745401961), at commit
`faa7b04` (June 2026). It's a separate project now, with its own direction: iOS support, tables with
formulas, source mode and the formatting API are new, and wiki-links are gone. The original's TextKit 2
foundation (the parser, the styler and the layout fragments) is still at its heart. Thank you to its
authors for sharing it.

Fixes from the original are ported selectively. See [NOTICE](NOTICE) for attribution.

## License

Apache 2.0, the same as the original. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
