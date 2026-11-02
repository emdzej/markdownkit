//
//  MarkerBar.swift
//  MarkdownEngine
//
//  The small floating bar for an image or a link under the caret (or, on
//  macOS, under the pointer): image size and alignment, card size, and
//  switching a link between plain text and a preview card. It writes the
//  `{…}` block after the construct, so nobody has to type markers.
//
//  Shown while the caret sits in an image or link (not while typing); on
//  macOS also while the pointer rests on a plain link. Lives in the text
//  view, so it scrolls with the text.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

#if os(macOS)
typealias MarkerEditingTextView = NativeTextView
#else
typealias MarkerEditingTextView = MarkdownUITextView
#endif

/// What a button in the bar (or a menu item) does.
enum MarkerAction: Equatable {
    case size(MarkdownAttributes.Size?)
    case align(MarkdownAttributes.Alignment?)
    case preview(Bool)

    var actionName: String {
        switch self {
        case .size: "Change Size"
        case .align: "Change Alignment"
        case .preview(let on): on ? "Show as Preview Card" : "Show as Link"
        }
    }

    var kinds: Set<MarkdownAttributeTarget.Kind> {
        switch self {
        case .size, .align: [.image, .link]
        case .preview: [.link, .bareURL]
        }
    }

    var change: (inout MarkdownAttributes) -> Void {
        switch self {
        case .size(let size): MarkdownAttributeEditing.setSize(size)
        case .align(let alignment): MarkdownAttributeEditing.setAlignment(alignment)
        case .preview(let on): MarkdownAttributeEditing.setPreview(on)
        }
    }
}

extension MarkerEditingTextView {

    var mdSelectedRange: NSRange {
        #if os(macOS)
        selectedRange()
        #else
        selectedRange
        #endif
    }

    /// Applies `action` to the image or link at `location` as one undoable
    /// edit. The caret stays where it was, clamped to the edited construct.
    @discardableResult
    func applyMarkerAction(_ action: MarkerAction, at location: Int,
                           kinds: Set<MarkdownAttributeTarget.Kind>? = nil) -> Bool {
        let text = string
        guard isEditable,
              let target = MarkdownAttributeEditing.target(at: location, in: text, kinds: kinds ?? action.kinds),
              let edit = MarkdownAttributeEditing.edit(target, change: action.change) else { return false }
        let selection = mdSelectedRange
        insertMarkdown(edit.replacement, replacing: edit.range, actionName: action.actionName)
        let length = (string as NSString).length
        let caret: Int
        if NSLocationInRange(selection.location, target.fullRange) || selection.location == NSMaxRange(target.fullRange) {
            caret = min(max(selection.location, edit.resultRange.location), NSMaxRange(edit.resultRange))
        } else if selection.location > NSMaxRange(target.fullRange) {
            caret = selection.location + (edit.replacement as NSString).length - edit.range.length
        } else {
            caret = selection.location
        }
        setSelectedRange(NSRange(location: min(max(caret, 0), length), length: 0))
        markerBar.refresh(after: true)
        return true
    }

    /// The image or link at the caret (nil with a range selected).
    var markerTargetAtCaret: MarkdownAttributeTarget? {
        let selection = mdSelectedRange
        guard selection.length == 0 else { return nil }
        return MarkdownAttributeEditing.target(at: selection.location, in: string)
    }

    /// Where `target` is drawn, in view coordinates: its source text, and
    /// whether it renders as a block (image or card on its own line).
    func markerAnchor(for target: MarkdownAttributeTarget) -> (rect: CGRect, isBlock: Bool)? {
        guard let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let storage = mdTextStorage, NSMaxRange(target.fullRange) <= storage.length,
              let start = tcs.location(tcs.documentRange.location, offsetBy: target.fullRange.location),
              let end = tcs.location(start, offsetBy: target.fullRange.length),
              let range = NSTextRange(location: start, end: end) else { return nil }
        var isBlock = false
        storage.enumerateAttribute(.latexIsBlock, in: target.fullRange) { value, _, stop in
            if value as? Bool == true { isBlock = true; stop.pointee = true }
        }
        var rect = CGRect.null
        tlm.ensureLayout(for: range)
        tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
            rect = rect.isNull ? segment : rect.union(segment)
            return true
        }
        guard !rect.isNull else { return nil }
        #if os(macOS)
        let origin = textContainerOrigin
        #else
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        #endif
        return (rect.offsetBy(dx: origin.x, dy: origin.y), isBlock)
    }
}

/// Owns the bar's hosting view and decides when it shows.
@MainActor
final class MarkerBarPresenter {
    weak var textView: MarkerEditingTextView?
    private var host: PlatformHost?
    private(set) var target: MarkdownAttributeTarget?
    /// The bar follows the pointer (a hovered link), not the caret.
    private var isHover = false
    private var typedSinceUpdate = false
    private var pendingUpdate = false
    #if os(macOS)
    private var hoverHide: DispatchWorkItem?
    #endif

    #if os(macOS)
    private typealias PlatformHost = NSHostingView<MarkerBarView>
    #else
    private typealias PlatformHost = UIHostingController<MarkerBarView>
    #endif

    var isVisible: Bool { target != nil }

    /// Typing hides the bar until the caret moves on its own.
    func textDidChange() {
        typedSinceUpdate = true
        if !isHover { hide() }
    }

    func selectionDidChange() { refresh(after: false) }

    /// Re-evaluates on the next runloop turn, after the text change (if any)
    /// that moved the caret has been reported. `force` ignores that typing.
    func refresh(after force: Bool) {
        if force { typedSinceUpdate = false }
        guard !pendingUpdate else { return }
        pendingUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingUpdate = false
            if self.typedSinceUpdate {
                self.typedSinceUpdate = false
                if !self.isHover { self.hide() }
                return
            }
            self.updateFromCaret()
        }
    }

    private func updateFromCaret() {
        guard let textView, textView.isEditable, isFocused(textView), let target = textView.markerTargetAtCaret else {
            if !isHover { hide() }
            return
        }
        show(target, hover: false)
    }

    #if os(macOS)
    /// The pointer rests on a plain link (or left it).
    func hover(over target: MarkdownAttributeTarget?) {
        hoverHide?.cancel()
        hoverHide = nil
        if let target {
            guard self.target == nil || isHover else { return }   // the caret's bar wins
            show(target, hover: true)
        } else if isHover {
            // A grace period to reach the bar.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isHover, !self.isPointerOverBar else { return }
                self.hide()
            }
            hoverHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    var isPointerOverBar: Bool {
        guard let host, let window = host.window else { return false }
        let point = host.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return host.bounds.insetBy(dx: -4, dy: -4).contains(point)
    }
    #endif

    func hide() {
        target = nil
        isHover = false
        #if os(macOS)
        host?.isHidden = true
        #else
        host?.view.isHidden = true
        #endif
    }

    private func isFocused(_ textView: MarkerEditingTextView) -> Bool {
        #if os(macOS)
        textView.window?.firstResponder === textView
        #else
        textView.isFirstResponder
        #endif
    }

    private func show(_ target: MarkdownAttributeTarget, hover: Bool) {
        guard let textView, let anchor = textView.markerAnchor(for: target) else { hide(); return }
        let content = MarkerBarView.Content(target)
        // Hovering only offers turning a plain link into a card.
        if hover, content.mode != .link { return }
        self.target = target
        isHover = hover
        let location = target.range.location
        let kind = target.kind
        let view = MarkerBarView(content: content, tint: Color(textView.configuration.theme.link)) { [weak textView] action in
            guard let textView else { return }
            textView.applyMarkerAction(action, at: location, kinds: [kind])
        }

        #if os(macOS)
        let host = self.host ?? {
            let h = NSHostingView(rootView: view)
            textView.addSubview(h)
            self.host = h
            return h
        }()
        host.rootView = view
        host.isHidden = false
        let size = host.fittingSize
        host.frame = CGRect(origin: position(for: size, anchor: anchor, in: textView), size: size)
        #else
        let host = self.host ?? {
            let h = UIHostingController(rootView: view)
            h.view.backgroundColor = .clear
            h.sizingOptions = [.intrinsicContentSize]
            textView.addSubview(h.view)
            self.host = h
            return h
        }()
        host.rootView = view
        host.view.isHidden = false
        let size = host.view.intrinsicContentSize
        host.view.frame = CGRect(origin: position(for: size, anchor: anchor, in: textView), size: size)
        textView.bringSubviewToFront(host.view)
        #endif
    }

    /// A block image / card: beside its (revealed) source line, which keeps
    /// the picture and the text around it clear. An inline link, or a line
    /// too long for that: above it, or below when there's no room above.
    private func position(for size: CGSize, anchor: (rect: CGRect, isBlock: Bool), in textView: MarkerEditingTextView) -> CGPoint {
        let visible = textView.visibleRect
        let gap: CGFloat = 6
        let maxX = textView.bounds.width - size.width - 8
        if anchor.isBlock, anchor.rect.maxX + 10 <= maxX {
            return CGPoint(x: (anchor.rect.maxX + 10).rounded(), y: (anchor.rect.midY - size.height / 2).rounded())
        }
        var y = anchor.rect.minY - size.height - gap
        if y < visible.minY + 2 { y = anchor.rect.maxY + gap }
        let x = min(max(anchor.rect.minX, 8), max(maxX, 8))
        return CGPoint(x: x.rounded(), y: y.rounded())
    }
}

/// The bar itself: a capsule of small buttons on a material.
struct MarkerBarView: View {
    enum Mode: Equatable { case image, card, link }

    struct Content: Equatable {
        var mode: Mode
        var size: MarkdownAttributes.Size?
        var alignment: MarkdownAttributes.Alignment?

        init(_ target: MarkdownAttributeTarget) {
            switch target.kind {
            case .image: mode = .image
            case .link: mode = target.isPreview ? .card : .link
            case .bareURL: mode = .link
            }
            size = target.attributes.size
            alignment = target.attributes.alignment
        }
    }

    let content: Content
    let tint: Color
    let apply: (MarkerAction) -> Void

    // Touch sizes on iPhone / iPad (44 pt targets per the HIG); compact on the Mac.
    #if os(iOS)
    private static let control: CGFloat = 40
    private static let symbolSize: CGFloat = 17
    private static let letterFont: Font = .body.weight(.semibold)
    private static let padding: CGFloat = 4
    #else
    private static let control: CGFloat = 24
    private static let symbolSize: CGFloat = 11
    private static let letterFont: Font = .caption.weight(.semibold)
    private static let padding: CGFloat = 3
    #endif

    var body: some View {
        HStack(spacing: 2) {
            switch content.mode {
            case .image:
                sizes([.small, .medium, .large, .full], original: true)
                separator
                alignments
            case .card:
                sizes([.small, .medium, .large], original: false)
                separator
                alignments
                separator
                button("Show as Link", symbol: "link", selected: false) { apply(.preview(false)) }
            case .link:
                Button { apply(.preview(true)) } label: {
                    Label(EngineStrings.localized("Preview Card"), systemImage: "text.below.photo")
                        .font(Self.control > 30 ? .subheadline.weight(.medium) : .caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .frame(height: Self.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(EngineStrings.localized("Show as Preview Card"))
            }
        }
        .padding(Self.padding)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        .foregroundStyle(.primary)
        .fixedSize()
    }

    private func sizes(_ sizes: [MarkdownAttributes.Size], original: Bool) -> some View {
        ForEach(sizes, id: \.self) { size in
            let selected = content.size == size || (content.size == nil && original == false && size == .medium)
            if size == .full {
                button("Full Width", symbol: "arrow.left.and.right", selected: selected) { apply(.size(selected ? nil : size)) }
            } else {
                Button { apply(.size(size == content.size && original ? nil : size)) } label: {
                    Text(Self.letter(size))
                        .font(Self.letterFont)
                        .frame(width: Self.control, height: Self.control)
                        .background(selected ? tint.opacity(0.2) : .clear, in: Circle())
                        .foregroundStyle(selected ? tint : .primary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(EngineStrings.localized(Self.title(size)))
            }
        }
    }

    private var alignments: some View {
        ForEach([MarkdownAttributes.Alignment.left, .center, .right], id: \.self) { alignment in
            let selected = (content.alignment ?? .left) == alignment
            button("Align \(alignment.rawValue.capitalized)", symbol: Self.symbol(alignment), selected: selected) {
                apply(.align(alignment == .left ? nil : alignment))
            }
        }
    }

    private var separator: some View {
        Divider().frame(height: Self.control * 0.6).padding(.horizontal, 2)
    }

    private func button(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Self.symbolSize, weight: .semibold))
                .frame(width: Self.control, height: Self.control)
                .background(selected ? tint.opacity(0.2) : .clear, in: Circle())
                .foregroundStyle(selected ? tint : .primary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(EngineStrings.localized(title))
        .accessibilityLabel(EngineStrings.localized(title))
    }

    static func letter(_ size: MarkdownAttributes.Size) -> String {
        switch size {
        case .icon: "I"
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        case .full: "F"
        }
    }

    static func title(_ size: MarkdownAttributes.Size) -> String {
        switch size {
        case .icon: "Icon"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .full: "Full Width"
        }
    }

    static func symbol(_ alignment: MarkdownAttributes.Alignment) -> String {
        switch alignment {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }
}
