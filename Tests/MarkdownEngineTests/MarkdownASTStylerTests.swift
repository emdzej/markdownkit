//
//  MarkdownASTStylerTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5b — the AST styler composes nested/combined inline styles instead
//  of overwriting them (the flat 18-pass styler's flaw).
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Testing
@testable import MarkdownEngineCore

@Suite("Phase 2.5b — AST styler font composition")
struct MarkdownASTStylerTests {

    private let base: CGFloat = 14
    private var fontName: String { PlatformFont.systemFont(ofSize: 14).fontName }

    // Ported from swift-markdown-engine #149.
    @MainActor
    @Test("scoped styling of a continuous list emits only intersecting ranges")
    func scopedContinuousListEmitsOnlyIntersectingRanges() {
                let text = String(
            repeating: "- [x] **fast** `native` [link](relative.md)\n",
            count: 2_000
        )
        let ns = text as NSString
        let target = ns.lineRange(
            for: ns.range(of: "- [x] **fast**", options: .backwards)
        )

        let attrs = MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: base,
            scopedRanges: [target]
        )

        #expect(!attrs.isEmpty)
        #expect(attrs.allSatisfy {
            NSIntersectionRange($0.range, target).length > 0
        })
    }

    @MainActor
    @Test("scoped list styling matches full effective attribute values")
    func scopedListMatchesFullEffectiveAttributeValues() {
                let text = "- plain *one*\n- [x] **done** `code`\n- [ ] [link](a.md)\n- final _four_\n"
        let ns = text as NSString
        let second = ns.lineRange(for: ns.range(of: "- [x]"))
        let fourth = ns.lineRange(for: ns.range(of: "- final"))
        let scope = [fourth, second]
        let caret = second.location + 3
        let full = MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: base,
            caretLocation: caret
        )
        let scoped = MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: base,
            caretLocation: caret,
            scopedRanges: scope
        )
        let fullStorage = NSMutableAttributedString(string: text)
        let scopedStorage = NSMutableAttributedString(string: text)
        TextStylingService.applyStyledRanges(
            full,
            paragraphs: scope,
            baseAttributes: [:],
            to: fullStorage
        )
        TextStylingService.applyStyledRanges(
            scoped,
            paragraphs: scope,
            baseAttributes: [:],
            to: scopedStorage
        )

        for range in scope {
            #expect(
                fullStorage.attributedSubstring(from: range).isEqual(
                    to: scopedStorage.attributedSubstring(from: range)
                )
            )
        }
    }

    /// Effective font at `pos`: the last styled range covering it that sets `.font`.
    private func font(in attrs: [StyledRange], at pos: Int) -> PlatformFont? {
        var result: PlatformFont?
        for (range, a) in attrs where NSLocationInRange(pos, range) {
            if let f = a[.font] as? PlatformFont { result = f }
        }
        return result
    }

    /// Per-keystroke perf: scoping a restyle to the edited paragraph must produce
    /// the EXACT same attributes within that paragraph as a full-document style.
    /// This is the safety net for the `scopedRanges` fast path — it can't diverge
    /// from the full rebuild (no glitch).
    @MainActor
    @Test("scoped styling == full styling, clipped to the edited paragraph")
    func scopedMatchesFullForEditedParagraph() {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let text = "plain one\n\n**bold** in two `code`\n\n- item *x*\n\nhttps://example.com"
        let ns = text as NSString
        let para = ns.paragraphRange(for: NSRange(location: 13, length: 0))   // the `**bold**…` line
        func keys(_ scoped: [NSRange]?) -> String {
            let r = MarkdownASTStyler.styleAttributes(
                text: text, fontName: fontName, fontSize: base, scopedRanges: scoped
            ).filter { NSIntersectionRange($0.range, para).length > 0 }
            return styleKeySnapshot(r)
        }
        #expect(keys([para]) == keys(nil))
    }

    @Test("bold inside a heading stays heading-size and consistent (fixes # **n*o*des**)")
    func headingBoldComposesToHeadingSize() {
        let attrs = MarkdownASTStyler.styleAttributes(text: "# **n*o*des**", fontName: fontName, fontSize: base)
        // "# **n*o*des**": n=4, o=6, d=8
        let n = font(in: attrs, at: 4)
        let o = font(in: attrs, at: 6)
        let d = font(in: attrs, at: 8)

        // The fix: every emphasized char is the SAME (heading) size — not "o" big, "n/des" small.
        #expect(n?.pointSize == o?.pointSize)
        #expect(n?.pointSize == d?.pointSize)
        #expect((n?.pointSize ?? 0) > base)   // heading-size, not base

        // Correct composed traits.
        #expect(n?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(d?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(o?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
    }

    @Test("nested emphasis in a paragraph composes bold+italic")
    func paragraphNestedEmphasis() {
        let attrs = MarkdownASTStyler.styleAttributes(text: "**a *b* c**", fontName: fontName, fontSize: base)
        // "**a *b* c**": a=2, b=5, c=8
        let a = font(in: attrs, at: 2)
        let b = font(in: attrs, at: 5)
        #expect(a?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(a?.fontDescriptor.symbolicTraits.contains(.italic) == false)
        #expect(b?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
    }

    /// Code is not prose: fenced blocks and inline `code` spans must carry
    /// `.spellingState: 0` so the system spell-checker leaves them alone,
    /// matching the existing convention that links / LaTeX / tables
    /// already follow.
    @Test("code blocks and inline code receive .spellingState: 0; prose does not")
    func codeRegionsSuppressSpellCheck() {
        let text = "prose word\n\n```\nfencedcd notaword\n```\n\nplain `inlnecode` tail"
        let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base)
        let ns = text as NSString
        let fencedContent = ns.range(of: "fencedcd notaword")
        let inlineSpan = ns.range(of: "`inlnecode`")
        let prose = ns.range(of: "prose word")

        // Pull every `.spellingState` value from styled ranges that intersect `r`.
        func spellingStates(intersecting r: NSRange) -> [Int] {
            attrs.compactMap { entry -> Int? in
                guard NSIntersectionRange(entry.range, r).length > 0 else { return nil }
                return entry.attributes[.spellingState] as? Int
            }
        }

        #expect(spellingStates(intersecting: fencedContent).contains(0))
        #expect(spellingStates(intersecting: inlineSpan).contains(0))
        #expect(spellingStates(intersecting: prose).isEmpty)
    }
}

/// Canonical, order-independent string of styled ranges so two style runs can be
/// compared for equality.
private func styleKeySnapshot(_ ranges: [StyledRange]) -> String {
    let lines = ranges
        .map { entry -> (NSRange, [String]) in
            (entry.range, entry.attributes.keys.map(\.rawValue).sorted())
        }
        .sorted { a, b in
            if a.0.location != b.0.location { return a.0.location < b.0.location }
            if a.0.length != b.0.length { return a.0.length < b.0.length }
            return a.1.joined(separator: ",") < b.1.joined(separator: ",")
        }
        .map { "@\(fmt($0.0)) keys=[\($0.1.joined(separator: ","))]" }
    return lines.isEmpty ? "(no styled ranges)" : lines.joined(separator: "\n")
}

private func fmt(_ r: NSRange) -> String {
    r.location == NSNotFound ? "∅" : "\(r.location)+\(r.length)"
}
