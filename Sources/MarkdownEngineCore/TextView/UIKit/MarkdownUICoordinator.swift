#if os(iOS) || os(visionOS)
//
//  MarkdownUICoordinator.swift
//  MarkdownEngine
//
//  UITextViewDelegate glue for the UIKit editor. Mirrors the restyle
//  scoping of the AppKit coordinator (`+TextDelegate`, `+Restyling`):
//  re-tokenize the document, recompute which tokens the caret activates,
//  and restyle only the paragraphs whose presentation can have changed.

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
    /// Start of the table shown as raw markdown ("Edit as Markdown"); nil
    /// while every table is a grid.
    var revealedTableLocation: Int?
    /// Images and link previews last styled; a change restyles the document.
    var lastContentFingerprint: AnyHashable?
    private var tableRevealPolicy: MarkdownDetection.TableRevealPolicy {
        configuration.renderingMode == .formatted ? .only(revealedTableLocation) : .caret
    }
    private var lastSyncedText: String
    private var activeTokenIndices: Set<Int> = []
    private var previousCaretLocation: Int?
    private var pendingEditedRange: NSRange?
    private var pendingPreEditActiveTokenIndices: Set<Int>?
    private var previousBacktickCount = 0
    private var cachedTokens: (text: String, length: Int, generation: UInt64, tokens: [MarkdownToken])?
    /// Character-edit generation of the text view's storage: token-cache hits
    /// in O(1) instead of an O(doc) string compare per call (several per
    /// keystroke). (Adapted from swift-markdown-engine #96.)
    private let storageEdits = TextStorageEditCounter()

    init(text: Binding<String>, fontName: String, fontSize: CGFloat) {
        _text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.lastSyncedText = text.wrappedValue
    }

    // MARK: Tokens

    /// Tokens of `text`, which must be `tv`'s current text.
    private func tokens(for text: String, in tv: MarkdownUITextView) -> [MarkdownToken] {
        storageEdits.track(tv.textStorage)
        let length = (text as NSString).length
        if let cachedTokens, cachedTokens.length == length {
            if cachedTokens.generation == storageEdits.generation { return cachedTokens.tokens }
            // Edited but possibly identical text: a UTF-16 compare, not the
            // Unicode-normalizing Swift `==`.
            if (cachedTokens.text as NSString).isEqual(to: text) {
                self.cachedTokens?.generation = storageEdits.generation
                return cachedTokens.tokens
            }
        }
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        cachedTokens = (text, length, storageEdits.generation, tokens)
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
            tv.pendingTableFocus = nil
            revealedTableLocation = nil
        }
        lastSyncedText = text
        previousBacktickCount = MarkdownDetection.tripleBacktickCount(in: text as NSString)
        rebuildAll(tv)
    }

    func rebuildAll(_ tv: MarkdownUITextView) {
        let (baseFont, paragraph) = baseFontAndStyle(tv)
        tv.baseFont = baseFont
        tv.configuration = configuration
        let string = tv.string
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let tokens = tokens(for: string, in: tv)
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: tv.selectedRange, tokens: tokens, in: ns, suppressed: !tv.isEditable, tableReveal: tableRevealPolicy
        )

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: configuration.theme.bodyText,
            .paragraphStyle: paragraph,
        ]
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
        // Write each character range once, left to right, with one complete
        // attribute dict per run: overlapping per-range writes re-split the run
        // array and intern an intermediate dict per call, which goes quadratic on
        // large notes. (Ported from swift-markdown-engine #107.)
        let runs = MarkdownStyler.flattenedRuns(ranges, base: baseAttrs, documentLength: full.length)
        let storage = tv.textStorage
        storage.beginEditing()
        storage.setAttributes(baseAttrs, range: full)
        for (range, attrs) in runs {
            storage.setAttributes(attrs, range: range)
        }
        storage.endEditing()

        tv.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont, paragraphStyle: paragraph, theme: configuration.theme
        )
        if let tlm = tv.textLayoutManager {
            tlm.invalidateLayout(for: tlm.documentRange)
        }
        tv.setNeedsLayout()
        tv.updateTableOverlays()
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
            precomputedTokens: tokens,
            configuration: configuration
        )
        tv.updateTableOverlays()
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

    /// Paragraphs of the overlay-rendering tokens (formulas, images, tables) the
    /// edit touches — their rendering spans whole paragraphs the edited-paragraph
    /// candidates may not cover. Restyling EVERY such paragraph on every
    /// keystroke widened the restyle to the whole document in formula- or
    /// table-rich notes. An edit in a table's source also refreshes the tables
    /// whose formulas may read it. (Ported from swift-markdown-engine #96.)
    private func overlayParagraphs(_ tokens: [MarkdownToken], touching edited: NSRange, in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        for token in tokens where [.inlineLatex, .blockLatex, .imageLink, .table].contains(token.kind)
            && (NSIntersectionRange(token.range, edited).length > 0 || NSLocationInRange(edited.location, token.range)) {
            result.append(ns.paragraphRange(for: token.range))
            if token.kind == .table {
                result += MarkdownFormulas.dependentTableParagraphs(in: ns as String, excluding: token.range)
            }
        }
        return result
    }

    // MARK: UITextViewDelegate

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText: String) -> Bool {
        guard let tv = textView as? MarkdownUITextView, !isProgrammaticEdit else { return true }
        pendingEditedRange = NSRange(location: range.location, length: replacementText.utf16.count)
        if tv.undoManager?.isUndoing == true || tv.undoManager?.isRedoing == true { return true }

        let string = tv.string
        let tokens = tokens(for: string, in: tv)
        pendingPreEditActiveTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: tv.selectedRange, tokens: tokens, in: string as NSString, suppressed: !tv.isEditable, tableReveal: tableRevealPolicy
        )
        if MarkdownInputHandler.handleBlockLatexAutoWrap(
            textView: tv, affectedCharRange: range, replacementString: replacementText,
            blockLatexTokens: tokens.filter { $0.kind == .blockLatex }
        ) { textChanged(tv); return false }
        if !MarkdownInputHandler.handleListInsertion(
            textView: tv, affectedCharRange: range, replacementString: replacementText,
            codeTokens: tokens.filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        ) {
            textChanged(tv)
            return false
        }
        return true
    }

    public func textViewDidChange(_ textView: UITextView) {
        (textView as? MarkdownUITextView)?.markerBar.textDidChange()
        guard let tv = textView as? MarkdownUITextView, !isProgrammaticEdit else { return }
        textChanged(tv)
    }

    /// Restyles after any text mutation (typed, programmatic, or undo).
    func textChanged(_ tv: MarkdownUITextView) {
        guard tv.markedTextRange == nil else { return }
        let string = tv.string
        if !(string as NSString).isEqual(to: lastSyncedText) {
            lastSyncedText = string
            text = string
        }

        let ns = string as NSString
        let caret = NSRange(location: min(tv.selectedRange.location, ns.length), length: 0)
        let tokens = tokens(for: string, in: tv)
        let preEdit = pendingPreEditActiveTokenIndices ?? activeTokenIndices
        pendingPreEditActiveTokenIndices = nil
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: caret, tokens: tokens, in: ns, suppressed: !tv.isEditable, tableReveal: tableRevealPolicy
        )

        // One allocation-free UTF-16 scan. (Ported from swift-markdown-engine #96.)
        let backticks = MarkdownDetection.tripleBacktickCount(in: ns)
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
        candidates += overlayParagraphs(tokens, touching: edited, in: ns)
        candidates += paragraphs(of: tokens, indices: activeTokenIndices.union(preEdit), in: ns)
        restyle(tv, paragraphs: candidates, tokens: tokens)
        previousCaretLocation = caret.location
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        (textView as? MarkdownUITextView)?.markerBar.selectionDidChange()
        (textView as? MarkdownUITextView)?.editorController?.refreshBlockStyle()
        // Revealing / collapsing source above a table moves it.
        (textView as? MarkdownUITextView)?.updateTableOverlays()
        guard let tv = textView as? MarkdownUITextView, !isProgrammaticEdit,
              tv.markedTextRange == nil, pendingEditedRange == nil else { return }
        if routeSelectionThroughTableGrid(tv) { return }
        let string = tv.string
        let ns = string as NSString
        let sel = tv.selectedRange
        let tokens = tokens(for: string, in: tv)
        let previous = activeTokenIndices
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: sel, tokens: tokens, in: ns, suppressed: !tv.isEditable, tableReveal: tableRevealPolicy
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

    // MARK: Tables

    private func tableToken(containing location: Int, in text: String, of tv: MarkdownUITextView) -> MarkdownToken? {
        tokens(for: text, in: tv).first {
            $0.kind == .table && location >= $0.range.location && location <= NSMaxRange($0.range)
        }
    }

    /// Syncs and restyles after the engine itself changed `range` (a table
    /// write-back, a file drop): those edits carry no typed edited range.
    func programmaticEditDidChange(in tv: MarkdownUITextView, range: NSRange) {
        textChanged(tv)
        let ns = tv.string as NSString
        guard NSMaxRange(range) <= ns.length else { return }
        // Formulas in other tables may read the edited one.
        let dependents = MarkdownFormulas.dependentTableParagraphs(in: tv.string, excluding: range)
        restyle(tv, paragraphs: [ns.paragraphRange(for: range)] + dependents, tokens: tokens(for: tv.string, in: tv))
    }

    /// Shows the table starting at `location` as raw markdown with the caret in it.
    func revealTableSource(at location: Int, in tv: MarkdownUITextView) {
        revealedTableLocation = location
        tv.becomeFirstResponder()
        tv.selectedRange = NSRange(location: location, length: 0)
        if let token = tableToken(containing: location, in: tv.string, of: tv) {
            restyle(tv, paragraphs: [(tv.string as NSString).paragraphRange(for: token.range)], tokens: tokens(for: tv.string, in: tv))
        }
    }

    /// A caret landing in a table's hidden source moves into its grid; leaving
    /// the revealed table turns it back into a grid. Returns true if it
    /// handed focus to a grid.
    private func routeSelectionThroughTableGrid(_ tv: MarkdownUITextView) -> Bool {
        guard configuration.renderingMode == .formatted else { return false }
        let selection = tv.selectedRange
        let table = tableToken(containing: selection.location, in: tv.string, of: tv)
        if let revealed = revealedTableLocation, table?.range.location != revealed {
            revealedTableLocation = nil
            let ns = tv.string as NSString
            if revealed < ns.length {
                restyle(tv, paragraphs: [ns.paragraphRange(for: NSRange(location: revealed, length: 0))], tokens: tokens(for: tv.string, in: tv))
            }
        }
        // Only a caret the user is moving in the text view enters a grid.
        guard tv.isFirstResponder, let table, selection.length == 0,
              table.range.location != revealedTableLocation else { return false }
        let fromBelow = (previousCaretLocation ?? 0) > NSMaxRange(table.range)
        let rows = MarkdownTable(source: (tv.string as NSString).substring(with: table.range))?.rowCount ?? 1
        return tv.focusTableCell(tableLocation: table.range.location, row: fromBelow ? rows - 1 : 0, column: 0)
    }

    public func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case .link(let url) = textItem.content, let onLinkClick else { return defaultAction }
        return UIAction { _ in onLinkClick(url.absoluteString) }
    }
}
#endif
