//
//  InlineSpanDensityTests.swift
//  MarkdownEngineTests
//
//  Inline parse cost against span density within one region.
//  Ported from swift-markdown-engine #140 (issue #109).
//
//  Two halves, and the first is the one that matters: the containment rewrite
//  has to be a pure performance change. `corpusFingerprint` folds the parsed
//  tree of 4000 pseudo-random inputs into one value, recorded on THIS repo's
//  PRE-rewrite parser (MarkdownKit before the #140 port; upstream's value does
//  not apply — no wiki links, extension registry or #118 here). The baseline
//  covers shapes nobody would think to write by hand.
//
//  Re-record it ONLY on a parser that predates the rewrite, otherwise it just
//  ratifies whatever the rewrite does. It is also a bare hash: when it fails,
//  diff `String(describing:)` per input against the old parser to see what moved.
//
//  The second half asserts the cost curve is linear in spans rather than
//  quadratic, so the scans can't quietly come back.
//

import Foundation
import Testing
@testable import MarkdownEngineCore

@Suite("Inline parse cost vs. span density")
struct InlineSpanDensityTests {

    // MARK: - Corpus

    /// Deterministic LCG — the corpus must be identical across builds for the
    /// fingerprint to mean anything, and `SystemRandomNumberGenerator` isn't.
    private struct LCG {
        var state: UInt64 = 0x2545F4914F6CDD1D
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// Fragments chosen to collide: bare and paired delimiters, escapes, and
    /// the openers of every claimed-span construct, so the corpus is dense in
    /// half-formed and nested spans rather than in valid markdown.
    private static let atoms = [
        "a", "bb", " ", "  ", "*", "**", "_", "__", "`", "``", "\\", "\\*", "\\`",
        "[", "]", "(", ")", "![", "[[", "]]", "|", "$", "==", "~~", "url", "http://e.com/x",
        "\n", "word", ".", "!", "*a*", "**b**", "`c`", "[d](e)", "[[f|g]]", "$h$",
    ]

    private func corpus(_ count: Int) -> [String] {
        var rng = LCG()
        return (0..<count).map { _ in
            var s = ""
            for _ in 0..<(3 + rng.next(14)) { s += Self.atoms[rng.next(Self.atoms.count)] }
            return s
        }
    }

    /// Swift's `Hasher` is per-process seeded, so fold by hand.
    private func fingerprint(_ strings: [String]) -> String {
        var fnv: UInt64 = 0xcbf29ce484222325
        func fold(_ s: String) {
            for b in s.utf8 { fnv = (fnv ^ UInt64(b)) &* 0x100000001b3 }
        }
        for s in strings {
            fold(s)
            fold(String(describing: InlineParser.parse(s)))
        }
        return String(fnv, radix: 16)
    }

    @Test("the containment rewrite changes no tree in a 4000-input corpus")
    func corpusFingerprint() {
        #expect(fingerprint(corpus(4000)) == "7f4c1031946a7b9b")
    }

    // MARK: - Cost curve

    /// Minimum of several runs: scheduler noise only ever adds time, so the
    /// floor is the stable statistic. Means would make this a flake.
    private func msPerParse(_ text: String) -> Double {
        var best = Double.infinity
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20 { _ = DocumentAST.parse(text) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 20 / 1_000_000
            best = min(best, ms)
        }
        return best
    }

    private func paragraph(_ n: Int, _ make: (Int) -> String) -> String {
        (0..<n).map(make).joined(separator: " ")
    }

    /// 6x the spans in one paragraph should cost ~6x, not ~30x.
    ///
    /// Upstream picked 8 as the geometric midpoint of its measured gap. Here
    /// (debug build, one machine) the rewrite measured 3.6x-5.5x and the old
    /// parser 16.7x-30.8x, so 8 still separates them with room on both sides.
    private func expectLinearInSpans(_ label: String, _ make: (Int) -> String) {
        let small = msPerParse(paragraph(40, make))
        let large = msPerParse(paragraph(240, make))
        let growth = large / small

        #expect(growth < 8, "\(label): 6x spans cost \(String(format: "%.1f", growth))x parse")
    }

    @Test("code spans: parse cost is linear in spans per paragraph")
    func codeSpanDensity() { expectLinearInSpans("code") { "`word\($0)`" } }

    @Test("links: parse cost is linear in spans per paragraph")
    func linkDensity() { expectLinearInSpans("links") { "[word\($0)](https://e.com/\($0))" } }

    @Test("emphasis: parse cost is linear in spans per paragraph")
    func emphasisDensity() { expectLinearInSpans("emphasis") { "*word\($0)*" } }

    /// The pathological case the issue was filed from: escapes and code spans
    /// together, where every later pass used to rescan every claimed range.
    @Test("a paragraph mixing claimed-span kinds stays linear")
    func mixedDensity() {
        expectLinearInSpans("mixed") { i in
            switch i % 4 {
            case 0: return "`code\(i)`"
            case 1: return "\\*lit\(i)\\*"
            case 2: return "*em\(i)*"
            default: return "[l\(i)](u\(i))"
            }
        }
    }
}
