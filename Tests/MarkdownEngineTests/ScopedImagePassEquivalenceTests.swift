//
//  ScopedImagePassEquivalenceTests.swift
//  MarkdownEngineTests
//
//  Guards the scope culling ported from swift-markdown-engine #96: the image
//  passes (block/inline LaTeX, image links, link previews, tables,
//  frontmatter) skip tokens outside the restyle's bounding range. The apply
//  loop clips everything to the scoped paragraphs, so a scoped pass must land
//  exactly what the full pass lands inside them. Rendered images are fresh
//  objects per pass, so image-valued attributes compare by type.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Testing
@testable import MarkdownEngineCore

@MainActor
@Suite("Scoped image-pass equivalence")
struct ScopedImagePassEquivalenceTests {

    private static let corpus: [(name: String, text: String)] = [
        ("formulas", "Intro $a+b$ text.\n\nMiddle $x^2$ and $y$.\n\n$$\nE = mc^2\n$$\n\nTail $z$.\n"),
        ("tables", "| a | b |\n|---|---|\n| 1 | 2 |\n\nprose\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n| c | d |\n|---|---|\n| 3 | 4 |\n"),
        ("images", "![alt](img.png)\n\ntext ![i](x.png){.icon} more\n\n[site](https://e.com){preview}\n\nend\n"),
        ("frontmatter", "---\ntitle: T\ntags: [a, b]\n---\n\n# H\n\nbody $q$\n"),
        ("mixed", "# T\n\n- item $m$\n- item\n\n| a |\n|---|\n| $k$ |\n\n```\n$notlatex$\n```\n\nlast $w$\n"),
    ]

    private func lines(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var cursor = 0
        while cursor < ns.length {
            let p = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            out.append(p)
            cursor = NSMaxRange(p)
        }
        return out
    }

    private func applied(_ text: String, paragraphs: [NSRange], scoped: Bool) -> NSAttributedString {
        let font = PlatformFont.systemFont(ofSize: 14)
        let storage = NSMutableAttributedString(string: text)
        TextStylingService.applyStyledRanges(
            MarkdownStyler.styleAttributes(
                text: text, fontName: font.fontName, fontSize: 14, caretLocation: -1,
                activeTokenIndices: [], scopedRanges: scoped ? paragraphs : nil
            ),
            paragraphs: paragraphs,
            baseAttributes: [.font: font],
            to: storage
        )
        return storage
    }

    /// Attribute runs of `range`, with fresh-per-pass objects reduced to their type.
    private func runs(_ s: NSAttributedString, _ range: NSRange) -> [String] {
        var out: [String] = []
        s.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            let parts = attrs.map { key, value -> String in
                let shown: String
                switch value {
                case is PlatformImage, is TableRenderInfo: shown = String(describing: type(of: value))
                case let object as NSObject: shown = object.description
                default: shown = String(describing: type(of: value))
                }
                return "\(key.rawValue)=\(shown)"
            }.sorted()
            out.append("\(r.location),\(r.length):\(parts.joined(separator: ";"))")
        }
        return out
    }

    @Test("every paragraph scope matches the full pass inside it")
    func singleParagraphScopes() {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        for entry in Self.corpus {
            for p in lines(entry.text) {
                let full = applied(entry.text, paragraphs: [p], scoped: false)
                let scoped = applied(entry.text, paragraphs: [p], scoped: true)
                #expect(runs(full, p) == runs(scoped, p), "\(entry.name) paragraph \(p)")
            }
        }
    }

    @Test("two-paragraph scopes match the full pass inside both")
    func twoParagraphScopes() {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        for entry in Self.corpus {
            let all = lines(entry.text)
            for i in all.indices {
                for j in all.indices where j > i + 1 {
                    let scope = [all[i], all[j]]
                    let full = applied(entry.text, paragraphs: scope, scoped: false)
                    let scoped = applied(entry.text, paragraphs: scope, scoped: true)
                    for region in scope {
                        #expect(runs(full, region) == runs(scoped, region), "\(entry.name) \(scope) region \(region)")
                    }
                }
            }
        }
    }
}
