//
//  BacktickCensusTests.swift
//  MarkdownEngineTests
//
//  Ported from swift-markdown-engine #96. The fence census is one UTF-16
//  scan instead of `components(separatedBy: "```")`; it must count exactly
//  like the expression it replaced, whole-text and range-limited.
//

import Foundation
import Testing
@testable import MarkdownEngineCore

@Suite("Backtick census")
struct BacktickCensusTests {

    private static let samples = [
        "", "`", "``", "```", "````", "`````", "``````",
        "a```b```c",
        "x\n```swift\nlet a = 1\n```\ny",
        "inline `code` only",
        "```````",
    ]

    @Test func matchesComponentsSemantics() {
        for sample in Self.samples {
            let expected = sample.components(separatedBy: "```").count - 1
            #expect(MarkdownDetection.tripleBacktickCount(in: sample as NSString) == expected,
                    "mismatch for \(sample.debugDescription)")
        }
    }

    @Test func rangeLimitedCountMatchesSubstring() {
        for sample in Self.samples {
            let ns = sample as NSString
            for end in 0...ns.length {
                let prefix = ns.substring(to: end)
                let expected = prefix.components(separatedBy: "```").count - 1
                #expect(MarkdownDetection.tripleBacktickCount(in: ns, range: NSRange(location: 0, length: end)) == expected,
                        "mismatch for \(sample.debugDescription) prefix \(end)")
            }
        }
    }
}
