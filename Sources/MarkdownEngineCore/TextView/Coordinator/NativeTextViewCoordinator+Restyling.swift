#if os(macOS)
//
//  NativeTextViewCoordinator+Restyling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Re-tokenization, paragraph-scoped restyling, and the inline-replacement
//  pipeline. The TextDelegate extension decides WHEN and on WHICH ranges to
//  restyle; this extension owns the tokenize cache and the actual call into
//  `TextStylingService`.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Atomically rebuilds contents + base attrs + Markdown styling from `text`.
    func rebuildTextStorageAndStyle(
        _ textView: NSTextView,
        from text: String,
        invalidateLayout: Bool = false
    ) {
        // Suppress the re-entrant textViewDidChangeSelection that `textView.string =`
        // and the setAttributedString transfer below fire synchronously (71ms of
        // redundant styling on a 346k note); the necessary side effects are replayed
        // once at the end of this method. (Ported from swift-markdown-engine #107.)
        isRebuildingDocument = true
        defer { isRebuildingDocument = false }
        // Storage is raw Markdown, shown as-is.
        let displayText = text

        // Claimed BEFORE the assignment: `textView.string =` re-enters
        // textViewDidChangeSelection synchronously, whose updateCodeBlockSelection
        // laid out the whole (still unstyled) document — 141ms / 7714 fragments that
        // the ensureLayout below rebuilds from scratch anyway. This rebuild's own
        // ensureLayout IS that one-shot per-document layout.
        didEnsureLayoutForCurrentDocument = true
        let textChanged = !(textView.string as NSString).isEqual(to: displayText)
        if textChanged {
            textView.string = displayText
        }
        lastSyncedText = text
        let nsDisplay = displayText as NSString
        let fullRange = NSRange(location: 0, length: nsDisplay.length)

        let (baseFont, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: configuration.theme.bodyText,
            .paragraphStyle: paragraph
        ]
        // ── Root cause & fix (2026-07) ────────────────────────────────────────
        // CPU+page-fault instrumentation proved the first per-process open of a large
        // note spent 12.5s of PURE CPU (blocked=2ms), writing 69k attributes to the LIVE
        // TextKit-2 storage and faulting in 315k pages / ~5GB; a later open with warm
        // pages does the identical work in 78ms. So the whole styled string is built on a
        // DETACHED NSMutableAttributedString and handed to the live storage in ONE
        // transfer — the expensive first-touch happens off the layout-connected storage.
        let built = NSMutableAttributedString(string: displayText)
        built.setAttributes(baseAttrs, range: fullRange)

        let parsed = parsedDocument(for: displayText)
        let tokens = parsed.tokens
        // A rebuild replaces the text under the code-block token cache, which
        // only the typing / caret paths refresh. After a programmatic swap
        // (document switch, external binding change) a deferred refresh would
        // cut the new text with the previous document's ranges. Hand over this
        // text's code blocks here. (Ported from swift-markdown-engine #162.)
        cachedCodeBlockTokens = tokens.enumerated()
            .filter { $0.element.kind == .codeBlock }
            .map { (index: $0.offset, token: $0.element) }
        // Hide caret from styling when read-only, else clicks reveal raw token syntax.
        let caretLocation = textView.isEditable ? textView.selectedRange().location : -1
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: tokens,
            in: nsDisplay,
            suppressed: !textView.isEditable, tableReveal: tableRevealPolicy
        )

        let ranges = MarkdownStyler.styleAttributes(
            text: displayText,
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            caretLocation: caretLocation,
            activeTokenIndices: activeTokenIndices,
            precomputedTokens: tokens,
            configuration: configuration
        )
        // Per-key `addAttribute` on the live storage interns a short-lived
        // intermediate dict per call into Foundation's weak attribute-dictionary
        // table, which turns quadratic on large notes. Coalescing to
        // non-overlapping runs and writing each with ONE `setAttributes` on the
        // detached string interns one live dict per run.
        let runs = MarkdownStyler.flattenedRuns(ranges, base: baseAttrs,
                                                documentLength: fullRange.length)
        for (range, attrs) in runs {
            built.setAttributes(attrs, range: range)
        }

        // New text: ONE live-storage mutation carries the whole styled document across
        // (the characters were just replaced anyway). Same text (font/theme change,
        // Writing Tools undo): write the same runs in place instead, so no character
        // edit resets the selection, spelling markers or undo state.
        textView.textStorage?.beginEditing()
        if textChanged {
            textView.textStorage?.setAttributedString(built)
        } else {
            built.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
                textView.textStorage?.setAttributes(attrs, range: range)
            }
        }
        textView.textStorage?.endEditing()

        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: configuration.theme
        )

        if let tlm = textView.textLayoutManager {
            if invalidateLayout {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // The re-entrant textViewDidChangeSelection was suppressed for this rebuild
        // (isRebuildingDocument), so replay its selection-derived side effects that
        // nothing else runs afterwards: spell/grammar/quote toggles and the
        // bold/italic selection state for the loaded caret. Also seed the selection
        // bookkeeping the next real selection change diffs against, so it starts
        // from the loaded document instead of the previous one's stale caret.
        // (The code-block overlay refresh is scheduled by the wrapper after the
        // rebuild.) Active Writing Tools skips it, as the handler itself would.
        if !isWritingToolsActive {
            let finalSelection = textView.selectedRange()
            updateSelectionStates(textView)
            updateAutocorrectSettings(
                textView,
                caretLocation: finalSelection.location,
                codeTokens: parsed.codeTokens,
                latexTokens: parsed.latexTokens,
                allTokens: parsed.tokens
            )
            previousActiveTokenIndices = activeTokenIndices
            previousCaretLocation = finalSelection.location
        }

        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    /// Image and preview-card sizes and alignment depend on the column width;
    /// restyle those paragraphs once the width has settled (debounced for live resize).
    func scheduleWidthDependentRestyle(_ textView: NSTextView) {
        widthRestyleWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak textView] in
            guard let self, let textView else { return }
            let text = textView.string
            let ns = text as NSString
            let paragraphs = MarkdownTokenizer.parseTokensViaAST(in: text)
                .filter { $0.kind == .imageLink || $0.kind == .frontmatter || ($0.kind == .link && $0.markerRanges.count > 4) }
                .map { ns.paragraphRange(for: $0.range) }
            guard !paragraphs.isEmpty else { return }
            self.restyleTextView(textView, paragraphCandidates: paragraphs)
        }
        widthRestyleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func restyleTextView(
        _ textView: NSTextView,
        paragraphCandidates: [NSRange],
        tokens: [MarkdownToken]? = nil
    ) {
        let (baseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )

        TextStylingService.restyle(
            textView: textView,
            layoutBridge: layoutBridge,
            paragraphCandidates: paragraphCandidates,
            baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            caretLocation: textView.isEditable ? textView.selectedRange().location : -1,
            activeTokenIndices: activeTokenIndices,
            precomputedTokens: tokens,
            configuration: configuration
        )
        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    func parsedDocument(for text: String) -> ParsedDocument {
        if cachedParsedText == text, let cachedParsedDocument {
            return cachedParsedDocument
        }

        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        var codeTokens: [MarkdownToken] = []
        var latexTokens: [MarkdownToken] = []
        var blockLatexTokens: [MarkdownToken] = []

        codeTokens.reserveCapacity(tokens.count / 2)
        latexTokens.reserveCapacity(tokens.count / 4)
        blockLatexTokens.reserveCapacity(tokens.count / 4)

        for token in tokens {
            switch token.kind {
            case .codeBlock, .inlineCode:
                codeTokens.append(token)
            case .inlineLatex:
                latexTokens.append(token)
            case .blockLatex:
                blockLatexTokens.append(token)
            default:
                break
            }
        }

        let parsed = ParsedDocument(
            tokens: tokens,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            blockLatexTokens: blockLatexTokens
        )
        cachedParsedText = text
        cachedParsedDocument = parsed
        return parsed
    }

    func paragraphRanges(
        in text: NSString,
        intersecting editedRange: NSRange
    ) -> [NSRange] {
        guard text.length > 0 else { return [] }
        guard editedRange.location != NSNotFound else { return [] }

        var start = editedRange.location
        let end = min(NSMaxRange(editedRange), text.length)
        if start >= text.length {
            start = max(0, text.length - 1)
        }
        if end <= start {
            return [text.paragraphRange(for: NSRange(location: start, length: 0))]
        }

        var ranges: [NSRange] = []
        var cursor = start
        while cursor < end {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(paragraph)
            let next = NSMaxRange(paragraph)
            if next <= cursor { break }
            cursor = next
        }
        return ranges
    }

    func tokenRestyleParagraphs(
        in text: NSString,
        tokens: [MarkdownToken],
        currentActiveTokenIndices: Set<Int>,
        previousActiveTokenIndices: Set<Int>
    ) -> [NSRange] {
        var paragraphs: [NSRange] = []
        let indicesToStyle = currentActiveTokenIndices.union(previousActiveTokenIndices)

        for idx in indicesToStyle where idx >= 0 && idx < tokens.count {
            let token = tokens[idx]
            paragraphs.append(text.paragraphRange(for: token.range))

            if token.kind == .codeBlock || token.kind == .blockLatex {
                for markerRange in token.markerRanges {
                    paragraphs.append(text.paragraphRange(for: markerRange))
                }
            }
        }

        return paragraphs
    }

    func restyleParagraphs(_ paragraphs: [NSRange], in textView: NSTextView) {
        let parsed = parsedDocument(for: textView.string)
        let tokens = parsed.tokens
        let nsText = textView.string as NSString
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: tokens,
            in: nsText,
            suppressed: !textView.isEditable, tableReveal: tableRevealPolicy
        )
        restyleTextView(textView, paragraphCandidates: paragraphs, tokens: tokens)
    }

}

#endif
