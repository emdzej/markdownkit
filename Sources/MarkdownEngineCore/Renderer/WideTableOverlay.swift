#if os(macOS)
//
//  WideTableOverlay.swift
//  MarkdownEngine
//
//  NSScrollView subview of NativeTextView hosting a table's `TableGridView`,
//  with native horizontal scrolling for tables wider than the text column.
//  Sidesteps TextKit 2's fragment surface cache that defeats in-fragment
//  custom scrolling.
//

import AppKit

// MARK: - Faint scroller

/// Legacy scroller with a fainter knob.
final class SubtleScroller: NSScroller {
    override func drawKnobSlot(in slot: CGRect, highlight: Bool) {
        // Transparent track — only the knob is drawn.
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 1, knob.height > 1 else { return }
        let thickness: CGFloat = 5
        let pill = knob.insetBy(dx: 2, dy: max(0, (knob.height - thickness) / 2))
        PlatformColor.secondaryLabelColor.withAlphaComponent(0.3).setFill()   // ← faintness; tweak here
        PlatformBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
    }
}

// MARK: - Overlay view

final class WideTableOverlay: NSScrollView {

    /// Hash of table source; key for offset persistence + reconcile lookup.
    var sourceID: Int

    /// Start of the table's source in the document.
    var tableLocation: Int { gridView.info.sourceRange.location }

    /// Weak parent ref for offset persistence + caret forwarding.
    weak var ownerTextView: NativeTextView?

    /// Table's left-edge offset (breakout: text-column left); scrollable space.
    var leftContentInset: CGFloat = 0 {
        didSet {
            guard abs(contentInsets.left - leftContentInset) > 0.5 else { return }
            contentInsets = NSEdgeInsets(top: 0, left: leftContentInset, bottom: 0, right: 0)
        }
    }

    let gridView: TableGridView

    init(sourceID: Int, info: TableRenderInfo, ownerTextView: NativeTextView) {
        self.sourceID = sourceID
        self.ownerTextView = ownerTextView
        self.gridView = TableGridView(info: info, textView: ownerTextView)

        super.init(frame: .zero)

        hasHorizontalScroller = true
        hasVerticalScroller = false
        // Auto-hide: only show the scroller when the table actually overflows.
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
        // Legacy scroller, fainter knob (see SubtleScroller).
        scrollerStyle = .legacy
        let subtleScroller = SubtleScroller()
        subtleScroller.scrollerStyle = .legacy
        horizontalScroller = subtleScroller
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        horizontalScroller?.controlSize = .small
        automaticallyAdjustsContentInsets = false

        documentView = gridView

        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollOffsetDidChange),
            name: NSScrollView.didLiveScrollNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollOffsetDidChange),
            name: NSScrollView.didEndLiveScrollNotification, object: self
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Clamp vertical scroll to 0 on every layout — kills sub-pixel wobble.
    override func tile() {
        super.tile()
        let origin = contentView.bounds.origin
        if origin.y != 0 {
            contentView.scroll(to: CGPoint(x: origin.x, y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    /// Forward everything except clearly-horizontal events to the outer
    /// document scroll. Zero-delta phase/momentum lifecycle events count
    /// as "not horizontal" so the outer scroll view still receives the
    /// gesture-ended notifications it needs to stop cleanly.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }


    /// Swap in the re-rendered table after a restyle.
    func update(info: TableRenderInfo) {
        if gridView.info !== info { gridView.update(info: info) }
    }

    var horizontalOffset: CGFloat {
        get { contentView.bounds.origin.x }
        set {
            contentView.scroll(to: CGPoint(x: max(0, newValue), y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    @objc private func scrollOffsetDidChange() {
        ownerTextView?.tableHorizontalScrollOffsets[sourceID] = horizontalOffset
    }
}

// MARK: - NativeTextView reconcile extension

extension NativeTextView {

    /// Coalesce overlay updates to one per runloop tick (resize fires bursts); first run is sync to avoid a load flash.
    func updateWideTableOverlays() {
        if wideTableOverlays.isEmpty {
            performWideTableOverlayUpdate()
            return
        }
        if pendingWideTableOverlayUpdate { return }
        pendingWideTableOverlayUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingWideTableOverlayUpdate = false
            self.performWideTableOverlayUpdate()
        }
    }

    /// Cheap per-frame overlay shift when the container moves the text view
    /// vertically (header band growing/collapsing). Breakout overlays are
    /// SIBLINGS in the container whose frames bake in the text view's offset
    /// at update time; non-breakout overlays are text-view subviews and move
    /// with it automatically.
    func shiftWideTableOverlays(byY deltaY: CGFloat) {
        guard configuration.readingWidth != nil, !wideTableOverlays.isEmpty else { return }
        for (_, overlay) in wideTableOverlays {
            var f = overlay.frame
            f.origin.y += deltaY
            overlay.frame = f
        }
    }

    /// Cheap per-frame overlay reposition on width change (no layout) — keeps tables glued to the text during resize.
    func repositionWideTableOverlaysForWidthChange(insetDelta: CGFloat) {
        guard configuration.readingWidth != nil, !wideTableOverlays.isEmpty else { return }
        // Overlays live in the full-width reading-column container; use its width.
        let viewWidth = (superview ?? self).bounds.width
        for (_, overlay) in wideTableOverlays {
            var f = overlay.frame
            f.origin.x = 0
            f.size.width = viewWidth
            overlay.frame = f
            overlay.leftContentInset = max(0, overlay.leftContentInset + insetDelta)
        }
    }

    /// Walk storage; create / position / destroy overlays to match attrs.
    func performWideTableOverlayUpdate() {
        guard let storage = textStorage,
              let bridge = layoutBridge,
              let container = bridge.firstTextContainer,
              let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else {
            removeAllWideTableOverlays()
            return
        }

        let containerWidth = container.size.width
        guard containerWidth.isFinite, containerWidth > 0 else { return }
        // Breakout: tables span full width, flush with the text column's left.
        let breakout = configuration.readingWidth != nil
        // Breakout host: the full-width reading-column container, else the text view itself.
        let host: NSView = breakout ? (superview ?? self) : self
        let viewWidth = host.bounds.width

        var seenSourceIDs: Set<Int> = []
        let fullRange = NSRange(location: 0, length: storage.length)

        // Cheap presence-check first: skip the full-document layout pass when
        // the doc has no tables. enumerateAttribute stops on first hit.
        var hasAnyTable = false
        storage.enumerateAttribute(.scrollableBlockSourceID, in: fullRange, options: []) { value, _, stop in
            if value is Int { hasAnyTable = true; stop.pointee = true }
        }
        guard hasAnyTable else {
            removeAllWideTableOverlays()
            return
        }

        // Settle layout before measuring — stale fragments would yield wrong anchor Ys.
        tlm.ensureLayout(for: tlm.documentRange)

        storage.enumerateAttribute(.scrollableBlockSourceID, in: fullRange, options: []) { value, attrRange, _ in
            guard let sourceID = value as? Int,
                  let info = storage.attribute(.tableRenderInfo, at: attrRange.location, effectiveRange: nil) as? TableRenderInfo else { return }
            seenSourceIDs.insert(sourceID)

            if let start = tcs.location(tcs.documentRange.location, offsetBy: attrRange.location),
               let end = tcs.location(start, offsetBy: attrRange.length),
               let textRange = NSTextRange(location: start, end: end) {
                tlm.ensureLayout(for: textRange)
            }

            let anchorRect = bridge.boundingRect(forCharacterRange: attrRange, in: container)
            guard !anchorRect.isEmpty else { return }

            let totalHeight = (storage.attribute(.scrollableBlockTotalHeight, at: attrRange.location, effectiveRange: nil) as? CGFloat) ?? info.layout.size.height
            // In breakout the overlay lives in the container, so add the column's X
            // offset and the text view's Y offset (the scroll-away header band).
            let columnLeft = (breakout ? frame.origin.x : 0) + textContainerOrigin.x + anchorRect.minX
            let breakoutTop = frame.origin.y + textContainerOrigin.y + anchorRect.minY
            let overlayFrame: CGRect = breakout
                ? CGRect(x: 0, y: breakoutTop, width: viewWidth, height: totalHeight)
                : CGRect(x: columnLeft, y: textContainerOrigin.y + anchorRect.minY, width: containerWidth, height: totalHeight)
            // Breakout: table starts at the text column's left edge; the left margin is scrollable space.
            let leftContentInset: CGFloat = breakout ? max(0, columnLeft) : 0

            // An edited table gets a new sourceID (content hash); keep its
            // overlay (scroll offset, focus) by matching the table's start.
            if wideTableOverlays[sourceID] == nil,
               let (oldID, moved) = wideTableOverlays.first(where: {
                   !seenSourceIDs.contains($0.key) && $0.value.tableLocation == info.sourceRange.location
               }) {
                wideTableOverlays.removeValue(forKey: oldID)
                moved.sourceID = sourceID
                wideTableOverlays[sourceID] = moved
            }
            if let existing = wideTableOverlays[sourceID] {
                if !existing.frame.equalTo(overlayFrame) {
                    // Invalidate both old + new region so the vacated area redraws.
                    host.setNeedsDisplay(existing.frame)
                    existing.frame = overlayFrame
                    host.setNeedsDisplay(overlayFrame)
                }
                existing.leftContentInset = leftContentInset
                existing.update(info: info)
            } else {
                let overlay = WideTableOverlay(sourceID: sourceID, info: info, ownerTextView: self)
                overlay.frame = overlayFrame
                overlay.leftContentInset = leftContentInset
                host.addSubview(overlay)
                wideTableOverlays[sourceID] = overlay
                let savedOffset = tableHorizontalScrollOffsets[sourceID] ?? 0
                if savedOffset > 0 { overlay.horizontalOffset = savedOffset }
            }
        }

        for (sourceID, overlay) in wideTableOverlays where !seenSourceIDs.contains(sourceID) {
            host.setNeedsDisplay(overlay.frame)
            overlay.removeFromSuperview()
            wideTableOverlays.removeValue(forKey: sourceID)
        }
        applyPendingTableFocus()
    }

    /// Drop all overlays synchronously (file switch path).
    func removeAllWideTableOverlays() {
        for (_, overlay) in wideTableOverlays { overlay.removeFromSuperview() }
        wideTableOverlays.removeAll()
    }
}

#endif
