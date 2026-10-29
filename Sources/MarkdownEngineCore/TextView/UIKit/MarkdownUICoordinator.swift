#if os(iOS) || os(visionOS)
//
//  MarkdownUICoordinator.swift
//  MarkdownEngine
//
//  UITextViewDelegate glue for the UIKit editor. Mirrors the restyle
//  scoping of the AppKit coordinator (`+TextDelegate`, `+Restyling`):
//  re-tokenize the document, recompute which tokens the caret activates,
//  and restyle only the paragraphs whose presentation can have changed.
//
//  Wiki-links are stored exactly as displayed here (no `[[Name|id]]`
//  storage transform).
//

import SwiftUI
import UIKit

public final class MarkdownUICoordinator: NSObject, UITextViewDelegate, ProgrammaticEditTracking {
    @Binding var text: String
    var configuration: MarkdownEditorConfiguration = .default
    var fontName: String
    var fontSize: CGFloat
    var onLinkClick: ((String) -> Void)?
    var documentId: String?

    var isProgrammaticEdit = false
    private var lastSyncedText: String
    private var activeTokenIndices: Set<Int> = []
    private var previousCaretLocation: Int?
    private var pendingEditedRange: NSRange?
    private var pendingPreEditActiveTokenIndices: Set<Int>?
    private var previousBacktickCount = 0
    private var cachedTokens: (text: String, tokens: [MarkdownToken])?

    init(text: Binding<String>, fontName: String, fontSize: CGFloat) {
        _text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.lastSyncedText = text.wrappedValue
    }

    // MARK: Tokens

    private func tokens(for text: String) -> [MarkdownToken] {
        if let cachedTokens, cachedTokens.text == text { return cachedTokens.tokens }
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        cachedTokens = (text, tokens)
        return tokens
    }

    private func baseFontAndStyle(_ tv: MarkdownUITextView) -> (PlatformFont, NSMutableParagraphStyle) {
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName, fontSize: fontSize,
            layoutBridge: tv.layoutBridge, configuration: configuration
        )
        return (font, style)
    }

    // MARK: Full rebuild

    /// Replaces the contents with `text` (if different) and styles the whole document.
    func load(_ text: String, into tv: MarkdownUITextView) {
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        if tv.text != text {
            tv.text = text
            tv.selectedRange = NSRange(location: 0, length: 0)
        }
        lastSyncedText = text
        previousBacktickCount = text.components(separatedBy: "```").count - 1
        rebuildAll(tv)
    }

    func rebuildAll(_ tv: MarkdownUITextView) {
        let (baseFont, paragraph) = baseFontAndStyle(tv)
        tv.baseFont = baseFont
        tv.configuration = configuration
        let string = tv.string
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let tokens = tokens(for: string)
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: tv.selectedRange, tokens: tokens, in: ns, suppressed: !tv.isEditable
        )

        let storage = tv.textStorage
        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: configuration.theme.bodyText,
            .paragraphStyle: paragraph,
        ], range: full)
        let ranges = MarkdownStyler.styleAttributes(
            text: string,
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: tv.layoutBridge,
            caretLocation: tv.isEditable ? tv.selectedRange.location : -1,
            activeTokenIndices: activeTokenIndices,
            precomputedTokens: tokens,
            configuration: configuration
        )
        for (range, attrs) in ranges where NSMaxRange(range) <= full.length {
            storage.addAttributes(attrs, range: range)
        }
        storage.endEditing()

        tv.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont, paragraphStyle: paragraph, theme: configuration.theme
        )
        if let tlm = tv.textLayoutManager {
            tlm.invalidateLayout(for: tlm.documentRange)
        }
        tv.setNeedsLayout()
    }

    // MARK: Scoped restyle

    private func restyle(_ tv: MarkdownUITextView, paragraphs: [NSRange], tokens: [MarkdownToken]) {
        let (baseFont, paragraphStyle) = baseFontAndStyle(tv)
        TextStylingService.restyle(
            textView: tv,
            layoutBridge: tv.layoutBridge,
            paragraphCandidates: paragraphs,
            baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            caretLocation: tv.isEditable ? tv.selectedRange.location : -1,
            activeTokenIndices: activeTokenIndices,
            wikiLinkIDProvider: { _ in nil },
            precomputedTokens: tokens,
            configuration: configuration
        )
    }

    private func paragraphs(of tokens: [MarkdownToken], indices: Set<Int>, in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        for idx in indices where idx >= 0 && idx < tokens.count {
            let token = tokens[idx]
            result.append(ns.paragraphRange(for: token.range))
            if token.kind == .codeBlock || token.kind == .blockLatex {
                result.append(contentsOf: token.markerRanges.map { ns.paragraphRange(for: $0) })
            }
        }
        return result
    }

    private func paragraphs(in ns: NSString, intersecting range: NSRange) -> [NSRange] {
        guard ns.length > 0, range.location != NSNotFound else { return [] }
        let start = min(range.location, ns.length - 1)
        let end = min(NSMaxRange(range), ns.length)
        guard end > start else { return [ns.paragraphRange(for: NSRange(location: start, length: 0))] }
        var result: [NSRange] = []
        var cursor = start
        while cursor < end {
            let p = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            result.append(p)
            guard NSMaxRange(p) > cursor else { break }
            cursor = NSMaxRange(p)
        }
        return result
    }

    /// Paragraphs that always need restyling because they render overlays.
    private func overlayParagraphs(_ tokens: [MarkdownToken], in ns: NSString) -> [NSRange] {
        tokens.filter { [.inlineLatex, .blockLatex, .imageEmbed, .table].contains($0.kind) }
            .map { ns.paragraphRange(for: $0.range) }
    }

    // MARK: UITextViewDelegate

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText: String) -> Bool {
        guard let tv = textView as? MarkdownUITextView, !isProgrammaticEdit else { return true }
        pendingEditedRange = NSRange(location: range.location, length: replacementText.utf16.count)
        if tv.undoManager?.isUndoing == true || tv.undoManager?.isRedoing == true { return true }

        let string = tv.string
        let tokens = tokens(for: string)
        pendingPreEditActiveTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: tv.selectedRange, tokens: tokens, in: string as NSString, suppressed: !tv.isEditable
        )
        if MarkdownInputHandler.handleBlockLatexAutoWrap(
            textView: tv, affectedCharRange: range, replacementString: replacementText,
            blockLatexTokens: tokens.filter { $0.kind == .blockLatex }
        ) { textChanged(tv); return false }
        if MarkdownInputHandler.handleImageEmbedAutoWrap(
            textView: tv, affectedCharRange: range, replacementString: replacementText,
            imageEmbedTokens: tokens.filter { $0.kind == .imageEmbed }
        ) { textChanged(tv); return false }
        if !MarkdownInputHandler.handleListInsertion(textView: tv, affectedCharRange: range, replacementString: replacementText) {
            textChanged(tv)
            return false
        }
        return true
    }

    public func textViewDidChange(_ textView: UITextView) {
        guard let tv = textView as? MarkdownUITextView, !isProgrammaticEdit else { return }
        textChanged(tv)
    }

    /// Restyles after any text mutation (typed, programmatic, or undo).
    func textChanged(_ tv: MarkdownUITextView) {
        guard tv.markedTextRange == nil else { return }
        let string = tv.string
        if string != lastSyncedText {
            lastSyncedText = string
            text = string
        }

        let ns = string as NSString
        let caret = NSRange(location: min(tv.selectedRange.location, ns.length), length: 0)
        let tokens = tokens(for: string)
        let preEdit = pendingPreEditActiveTokenIndices ?? activeTokenIndices
        pendingPreEditActiveTokenIndices = nil
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: caret, tokens: tokens, in: ns, suppressed: !tv.isEditable
        )

        let backticks = string.components(separatedBy: "```").count - 1
        defer { previousBacktickCount = backticks }
        if backticks != previousBacktickCount {
            // Fence opened/closed: everything after it may have changed meaning.
            restyle(tv, paragraphs: [NSRange(location: 0, length: ns.length)], tokens: tokens)
            previousCaretLocation = caret.location
            return
        }

        let edited = pendingEditedRange ?? caret
        pendingEditedRange = nil
        let current = ns.paragraphRange(for: caret)
        var candidates = [current] + paragraphs(in: ns, intersecting: edited)
        if current.location > 0 {
            candidates.append(ns.paragraphRange(for: NSRange(location: current.location - 1, length: 0)))
        }
        if NSMaxRange(current) < ns.length {
            candidates.append(ns.paragraphRange(for: NSRange(location: NSMaxRange(current), length: 0)))
        }
        candidates += overlayParagraphs(tokens, in: ns)
        candidates += paragraphs(of: tokens, indices: activeTokenIndices.union(preEdit), in: ns)
        restyle(tv, paragraphs: candidates, tokens: tokens)
        previousCaretLocation = caret.location
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        guard let tv = textView as? MarkdownUITextView, !isProgrammaticEdit,
              tv.markedTextRange == nil, pendingEditedRange == nil else { return }
        let string = tv.string
        let ns = string as NSString
        let sel = tv.selectedRange
        let tokens = tokens(for: string)
        let previous = activeTokenIndices
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: sel, tokens: tokens, in: ns, suppressed: !tv.isEditable
        )

        // Caret crossing in/out of task syntax or an HR line changes rendering
        // without changing the active-token set (neither is a token).
        let prevLoc = previousCaretLocation
        let crossedTask = prevLoc.flatMap { MarkdownStyler.taskSyntaxRange(at: $0, in: string) }
            != MarkdownStyler.taskSyntaxRange(at: sel.location, in: string)
        let crossedHR = prevLoc.flatMap { MarkdownStyler.hrLineRange(at: $0, in: string) }
            != MarkdownStyler.hrLineRange(at: sel.location, in: string)
        let crossedBullet = prevLoc.flatMap { MarkdownStyler.bulletSyntaxRange(at: $0, in: string) }
            != MarkdownStyler.bulletSyntaxRange(at: sel.location, in: string)
        let caretParagraph = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
        let prevParagraph = prevLoc.map { ns.paragraphRange(for: NSRange(location: min($0, ns.length), length: 0)) }
        previousCaretLocation = sel.location

        guard previous != activeTokenIndices || crossedTask || crossedHR || crossedBullet
                || prevParagraph != caretParagraph else { return }

        var candidates = [caretParagraph]
        if let prevParagraph { candidates.append(prevParagraph) }
        candidates += paragraphs(of: tokens, indices: activeTokenIndices.union(previous), in: ns)
        restyle(tv, paragraphs: candidates, tokens: tokens)
    }

    public func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case .link(let url) = textItem.content, let onLinkClick else { return defaultAction }
        let target = url.scheme == nil ? url.absoluteString.removingPercentEncoding ?? url.absoluteString : url.absoluteString
        return UIAction { _ in onLinkClick(target) }
    }
}
#endif
