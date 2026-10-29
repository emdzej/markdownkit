#if os(macOS)
//
//  NativeTextViewCoordinator.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Keeps the editor in sync while you type, updating formatting, selections,
// links, and other editing behavior in one place.
import AppKit
import SwiftUI

/// `NSTextViewDelegate` that bridges ``NativeTextViewWrapper`` and the
/// underlying `NSTextView`.
///
/// The coordinator is created automatically by SwiftUI; embedders never
/// construct one directly. Behaviors that don't fit in the main file live
/// in extensions (Autocorrect, CodeBlocks, Find,
/// Notifications, Restyling, TextDelegate, WritingTools).
public final class NativeTextViewCoordinator: NSObject, NSTextViewDelegate, ProgrammaticEditTracking {
    var documentId: String?
    /// Remembered scroll offset (`bounds.origin.y`) per `documentId` — saved on
    /// switch-away, restored on switch-back.
    var scrollOffsets: [String: CGFloat] = [:]
    @Binding var text: String
    var fontName: String
    var fontSize: CGFloat
    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            subscribeToBusNotifications(replacing: oldValue.services.bus)
            subscribeToAppearanceNotification()
        }
    }
    /// Last `ImageProvider.fingerprint()` value we've reflected in
    /// the textView's attributes. We cache it here because embedders that
    /// MUTATE the same provider over time (async URL fetches, etc.) would
    /// otherwise fool the wrapper's "did the embedder hand us a new
    /// fingerprint" check — re-reading the same object twice always
    /// returns the current value, regardless of when state changed.
    var lastImageFingerprint: AnyHashable?
    private var busObservers: [NSObjectProtocol] = []
    private var undoObservers: [NSObjectProtocol] = []
    private var registeredAppearanceObserverName: Notification.Name?
    weak var textView: NSTextView?
    /// Owns the scroll-away header (build, content refresh, collapse/expand,
    /// teardown). Created on first reconcile with a non-nil header.
    var headerController: ScrollingHeaderController?
    var layoutBridge: LayoutBridge?
    var layoutDelegate: MarkdownLayoutManagerDelegate?
    var onLinkClick: ((String) -> Void)?
    var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
    var didInitialFormatting: Bool = false
    /// One-shot guard so `updateCodeBlockSelection` only forces a full-document layout once per document.
    var didEnsureLayoutForCurrentDocument: Bool = false
    var lastSyncedText: String
    var isProgrammaticEdit: Bool = false
    /// Start location of the table shown as raw markdown ("Edit as Markdown");
    /// nil while every table is a grid. See `+Tables.swift`.
    var revealedTableLocation: Int?
    /// Pending restyle of width-dependent images after the column width changes.
    var widthRestyleWork: DispatchWorkItem?
    var isWritingToolsActive: Bool = false
    var wtStartDocumentId: String?
    weak var wtChildWindow: NSWindow?
    var wtInitialChildOrigin: CGPoint?
    var wtInitialSelectionRange: NSRange?
    enum WTMode { case unknown, proofread, rewrite }
    var wtDetectedMode: WTMode = .unknown
    var wtUndoObserverTokens: [NSObjectProtocol] = []
    var wtUndoneDuringSession: Bool = false
    var wtPostUndoSnapshot: String?
    var activeTokenIndices: Set<Int> = []
    var previousActiveTokenIndices: Set<Int> = []
    var previousBacktickCount: Int = 0

    var pendingEditedRange: NSRange? = nil
    var pendingPreEditActiveTokenIndices: Set<Int>? = nil
    var previousCaretLocation: Int? = nil
    /// Drag-select suppressed a restyle; replayed on the next non-drag selection change.
    var needsRestyleAfterDrag = false

    var cachedCodeBlockTokens: [(index: Int, token: MarkdownToken)] = []
    var cachedParsedText: String?
    var cachedParsedDocument: ParsedDocument?
    // Skip spellcheck property setters when the state wouldn't change.
    var cachedSpellingDisabled: Bool?

    // Mirrors the user's last-known preference for each spell/grammar toggle.
    // `updateAutocorrectSettings` reads these when restoring outside a
    // suppress zone, so caret movement no longer clobbers a manual "off".
    var userPrefersContinuousSpellChecking: Bool = true
    var userPrefersGrammarChecking: Bool = true
    var userPrefersAutomaticSpellingCorrection: Bool = true

    /// Fires after the user toggles a spell/grammar/auto-correction menu item.
    /// Embedders persist the returned policy (e.g. to `UserDefaults`) and feed
    /// it back via ``MarkdownEditorConfiguration/spellChecking`` on next launch.
    var onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)?

    var currentSpellCheckingPolicy: SpellCheckingPolicy {
        SpellCheckingPolicy(
            continuousSpellChecking: userPrefersContinuousSpellChecking,
            grammarChecking: userPrefersGrammarChecking,
            automaticSpellingCorrection: userPrefersAutomaticSpellingCorrection
        )
    }

    /// Called from ``NativeTextView`` toggle overrides after `super` flips the
    /// underlying property. Snapshots the text view's state, refreshes the
    /// cache so the next caret move doesn't immediately overwrite it, and
    /// notifies the embedder.
    func didToggleSpellCheckingPolicy(textView: NSTextView) {
        userPrefersContinuousSpellChecking = textView.isContinuousSpellCheckingEnabled
        userPrefersGrammarChecking = textView.isGrammarCheckingEnabled
        userPrefersAutomaticSpellingCorrection = textView.isAutomaticSpellingCorrectionEnabled
        // Invalidate the "didn't change" short-circuit so the next selection
        // update re-applies the preferences cleanly.
        cachedSpellingDisabled = nil
        onSpellCheckingPolicyChanged?(currentSpellCheckingPolicy)
    }

    struct ParsedDocument {
        let tokens: [MarkdownToken]
        let codeTokens: [MarkdownToken]
        let latexTokens: [MarkdownToken]
        let blockLatexTokens: [MarkdownToken]
    }

    init(text: Binding<String>,
         fontName: String,
         fontSize: CGFloat,
         onLinkClick: ((String) -> Void)?) {
        _text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.onLinkClick = onLinkClick
        self.lastSyncedText = text.wrappedValue
        super.init()
        // Init + didSet share this helper so the observer tracks whichever service is current.
        subscribeToAppearanceNotification()
    }

    /// (Re)register the syntax-highlighter appearance observer; idempotent and unsubscribes on nil.
    private func subscribeToAppearanceNotification() {
        let target = configuration.services.syntaxHighlighter.appearanceDidChangeNotification
        if registeredAppearanceObserverName == target { return }
        if let current = registeredAppearanceObserverName {
            NotificationCenter.default.removeObserver(self, name: current, object: nil)
        }
        registeredAppearanceObserverName = nil
        guard let name = target else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange(_:)),
            name: name,
            object: nil
        )
        registeredAppearanceObserverName = name
    }

    /// Subscribe to whichever bus notification names the current configuration
    /// supplies. Removes any previous subscriptions first so that swapping
    /// configurations at runtime doesn't double-fire handlers.
    private func subscribeToBusNotifications(replacing previous: MarkdownEditorBus) {
        busObservers.forEach(NotificationCenter.default.removeObserver(_:))
        busObservers.removeAll(keepingCapacity: true)

        let bus = configuration.services.bus
        let center = NotificationCenter.default

        if let name = bus.applyBoldRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleBoldNotification(notification)
            })
        }
        if let name = bus.applyItalicRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleItalicNotification(notification)
            })
        }
        if let name = bus.applyHeadingRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleHeadingNotification(notification)
            })
        }
        if let name = bus.findScrollToRange {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleFindScrollToRange(notification)
            })
        }
        if let name = bus.findClearHighlights {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleFindClearHighlights(notification)
            })
        }
    }

    // Find-in-document highlight handlers live in
    // `NativeTextViewCoordinator+Find.swift`.

    // Methods are split across the following extensions:
    //   - +TextDelegate    — NSTextViewDelegate hot path
    //   - +Restyling       — restyle pipeline + parsedDocument cache
    //   - +CodeBlocks      — copy-button overlay
    //   - +Find            — find-in-document highlights
    //   - +Notifications   — bus + appearance bridge
    //   - +Autocorrect     — spell/grammar/quote toggles
    //   - +WritingTools    — macOS 15+ Writing Tools session

    /// AppKit applies undo/redo to the text storage without posting
    /// `NSText.didChangeNotification`, so `textDidChange` never sees it.
    /// Re-sync the binding (and restyle) from the undo manager's own
    /// notifications; a no-op when the text already matches.
    func subscribeToUndoNotifications() {
        guard undoObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            undoObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, let tv = self.textView,
                      let manager = notification.object as? UndoManager, manager === tv.undoManager else { return }
                self.syncAfterUndoRedo(tv)
            })
        }
    }

    private func syncAfterUndoRedo(_ tv: NSTextView) {
        guard !isWritingToolsActive, tv.string != lastSyncedText else { return }
        let current = tv.string
        lastSyncedText = current
        text = current
        restyleParagraphs([NSRange(location: 0, length: (current as NSString).length)], in: tv)
        (tv as? NativeTextView)?.updateWideTableOverlays()
    }

    deinit {
        undoObservers.forEach(NotificationCenter.default.removeObserver(_:))
        NotificationCenter.default.removeObserver(self)
        busObservers.forEach(NotificationCenter.default.removeObserver(_:))
    }
}

extension NSTextView {
    func viewRect(forCharacterRange range: NSRange, using bridge: LayoutBridge?) -> CGRect? {
        guard range.location != NSNotFound,
              let bridge = bridge,
              let textContainer = textContainer else { return nil }
        var boundingRect = bridge.boundingRect(forCharacterRange: range, in: textContainer)
        let containerOrigin = textContainerOrigin
        boundingRect.origin.x += containerOrigin.x
        boundingRect.origin.y += containerOrigin.y
        // The text view sits inside a container document view, offset by the header
        // band (y) and the reading-column centering (x), so its glyph rects
        // (text-view-local) must be lifted into the document view's space before
        // subtracting the scroll offset (which is in document-view space).
        // `convert(.zero, to: doc)` covers both offsets and self-zeroes if this text
        // view ever IS the document view.
        if let scrollView = enclosingScrollView {
            if let doc = scrollView.documentView, doc !== self {
                let originInDoc = convert(CGPoint.zero, to: doc)
                boundingRect.origin.x += originInDoc.x
                boundingRect.origin.y += originInDoc.y
            }
            let contentOffset = scrollView.contentView.bounds.origin
            boundingRect.origin.x -= contentOffset.x
            boundingRect.origin.y -= contentOffset.y
        }
        return boundingRect
    }
}


#endif
