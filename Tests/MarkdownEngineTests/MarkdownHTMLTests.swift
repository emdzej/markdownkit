//
//  MarkdownHTMLTests.swift
//  The note as HTML for printing / PDF export.
//

import Foundation
import Testing
@testable import MarkdownEngineCore

@Suite("HTML export")
struct MarkdownHTMLTests {
    private func html(_ md: String, _ options: MarkdownHTML.Options = MarkdownHTML.Options()) -> String {
        MarkdownHTML.body(for: md, options: options)
    }

    @Test func frontmatterBecomesChipsNotText() {
        let out = html("---\npinned: true\ntags: [work, Ideas]\nauthor: Ann\n---\n# Title\n")
        #expect(!out.contains("pinned:"))
        #expect(out.contains("nmw-properties"))
        #expect(out.contains("#work") && out.contains("#Ideas"))
        #expect(out.contains("<b>author</b> Ann"))
        #expect(out.contains("<h1>Title</h1>"))
        #expect(!html("---\npinned: true\n---\nx", MarkdownHTML.Options(showsProperties: false)).contains("nmw-properties"))
    }

    @Test func imageSizesAndAlignmentBecomeCSS() {
        let out = html("![cat](a b.png){.small .center}\n")
        #expect(out.contains("<figure class=\"nmw-figure nmw-center\">"))
        #expect(out.contains("max-width:min(100%,160px)"))
        #expect(html("![](x.png){.full}").contains("width:100%"))
        #expect(html("![](x.png){width=200}").contains("width:200px"))
    }

    @Test func imageSourcesAreResolvedOrLeftOut() {
        let resolved = html("![](pics/x.png)", MarkdownHTML.Options(resolveImage: { "file:///n/\($0)" }))
        #expect(resolved.contains("src=\"file:///n/pics/x.png\""))
        let missing = html("![alt](gone.png)", MarkdownHTML.Options(resolveImage: { _ in nil }))
        #expect(!missing.contains("<img") && missing.contains("[alt]"))
    }

    @Test func tableFormulasPrintTheirValues() {
        let md = "| a | b |\n|---|---:|\n| 3 | 4 |\n| sum | [?](#SUM(A1:B1)) |\n| bad | [?](#1/0) |\n"
        let out = html(md)
        #expect(out.contains(">7</span>"))
        #expect(out.contains("nmw-formula nmw-error") && out.contains("#DIV/0!"))
        #expect(!out.contains("[?]"))
        #expect(out.contains("text-align:right"))
    }

    @Test func columnWidthLineSetsColsAndIsNotPrinted() {
        let out = html("| a | b |\n|---|---|\n| 1 | 2 |\n{cols=\"30%,120\"}\n")
        #expect(out.contains("<col style=\"width:30%\">"))
        #expect(out.contains("<col style=\"width:120px\">"))
        #expect(!out.contains("cols="))
    }

    @Test func checklistsGetBoxesAndCheckedState() {
        let out = html("- [x] done\n- [ ] todo\n  - [ ] nested\n")
        #expect(out.contains("<li class=\"nmw-task nmw-done\"><span class=\"nmw-box\">☑</span>"))
        #expect(out.contains("☐"))
        #expect(out.components(separatedBy: "<ul").count == 3) // nested list
    }

    @Test func commentLinesAreHidden() {
        let out = html("<!-- budget -->\n| a |\n|---|\n| 1 |\n\nText\n")
        #expect(!out.contains("budget"))
        #expect(out.contains("<p>Text</p>"))
    }

    @Test func inlineMarkupAndLinks() {
        let out = html("Some **bold**, *it*, ~~gone~~, `code`, [site](https://swift.org), [note](Notes/Idea.md), www.apple.com #tag\nnext line")
        #expect(out.contains("<strong>bold</strong>"))
        #expect(out.contains("<em>it</em>"))
        #expect(out.contains("<del>gone</del>"))
        #expect(out.contains("<code>code</code>"))
        #expect(out.contains("<a class=\"nmw-link\" href=\"https://swift.org\">site</a>"))
        #expect(out.contains("<span class=\"nmw-link\">note</span>"))
        #expect(out.contains("href=\"https://www.apple.com\""))
        #expect(out.contains("<span class=\"nmw-tag\">#tag</span>"))
        #expect(out.contains("<br>next line"))
        #expect(!html("a < b & c").contains("a < b"))
    }

    @Test func previewLinksBecomeCards() {
        let options = MarkdownHTML.Options(preview: { _ in MarkdownHTML.LinkCard(title: "Swift", summary: "The language", subtitle: "swift.org") })
        let out = html("[Swift](https://swift.org){.preview}\n", options)
        #expect(out.contains("nmw-card") && out.contains("The language"))
        #expect(html("[Swift](https://swift.org){.preview}\n").contains("<a class=\"nmw-link\""))
    }

    @Test func codeBlocksAndQuotes() {
        let out = html("```swift\nlet x = 1 < 2\n```\n\n> quoted **bold**\n> more\n")
        #expect(out.contains("<pre class=\"nmw-code\" data-lang=\"swift\"><code>let x = 1 &lt; 2</code></pre>"))
        #expect(out.contains("<blockquote><p>quoted <strong>bold</strong><br>more</p>"))
    }

    @Test func cellAddresses() {
        #expect(Renderer.cellPositionForTests("C3")! == [3, 2])
        #expect(Renderer.cellPositionForTests("AA1")! == [1, 26])
    }
}
