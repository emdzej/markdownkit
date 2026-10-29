#if os(iOS) || os(visionOS)
//
//  MarkdownUITextView.swift
//  MarkdownEngine
//
//  UIKit counterpart of `NativeTextView`: a TextKit 2 `UITextView` that
//  hosts the shared parser / styler / layout fragment. Behavior that the
//  AppKit side spreads over `NativeTextView+*.swift` lives here in compact
//  form; it grows as features are ported.
//

import UIKit

final class MarkdownUITextView: UITextView {
    var configuration: MarkdownEditorConfiguration = .default
    var baseFont: PlatformFont = .preferredFont(forTextStyle: .body)
    var layoutBridge: LayoutBridge?
    /// Embedder hook for files dropped onto the editor; see `+FileDrop.swift`.
    var onDropFiles: FileDropHandler?

    /// Strongly held: NSTextLayoutManager.delegate is weak.
    private(set) var layoutDelegate = MarkdownLayoutManagerDelegate()

    // Table grid state; see `MarkdownUITextView+Tables.swift`.
    var tableOverlays: [Int: TableOverlayUIView] = [:]
    /// The image / link bar; see `MarkerBar.swift`.
    lazy var markerBar: MarkerBarPresenter = {
        let presenter = MarkerBarPresenter()
        presenter.textView = self
        return presenter
    }()
    var pendingTableOverlayUpdate = false
    var pendingTableFocus: TableCellFocus?
    private(set) lazy var keyboardKeeper: UITextField = {
        let field = UITextField(frame: .zero)
        field.isHidden = true
        return field
    }()
    private var lastLayoutWidth: CGFloat = 0

    init() {
        super.init(frame: .zero, textContainer: nil)
        // Opt into TextKit 2 explicitly; UITextView falls back to TextKit 1 if
        // anything touches `layoutManager`, which would bypass our fragments.
        guard let tlm = textLayoutManager else {
            assertionFailure("MarkdownUITextView requires TextKit 2")
            return
        }
        tlm.delegate = layoutDelegate
        tlm.mdHost = self
        layoutBridge = LayoutBridge(tlm)
        layoutBridge?.textView = self

        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        smartQuotesType = .no
        smartDashesType = .no
        autocapitalizationType = .sentences
        textContainer.lineFragmentPadding = 0

        addGestureRecognizer(checkboxTap)
        textDropDelegate = self

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.appearanceChanged()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Wide-table decisions and overlay frames depend on the column width.
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            (delegate as? MarkdownUICoordinator)?.rebuildAll(self)
        }
    }

    // MARK: Appearance

    private func appearanceChanged() {
        if let name = configuration.services.syntaxHighlighter.appearanceDidChangeNotification {
            NotificationCenter.default.post(name: name, object: self)
        }
        (delegate as? MarkdownUICoordinator)?.rebuildAll(self)
    }

    // MARK: Task checkboxes

    private lazy var checkboxTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCheckboxTap(_:)))
        tap.delegate = self
        return tap
    }()

    /// Range of the `[ ]` / `[x]` under `point` (view coordinates), if any.
    private func checkboxRange(at point: CGPoint) -> (range: NSRange, checked: Bool)? {
        guard let bridge = layoutBridge else { return nil }
        let containerPoint = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let storage = textStorage
        var hit: (NSRange, Bool)?
        storage.enumerateAttribute(.taskCheckbox, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let checked = value as? Bool else { return }
            // Generous touch target: Apple HIG minimum is 44pt.
            let rect = bridge.boundingRect(forCharacterRange: range, in: textContainer).insetBy(dx: -12, dy: -8)
            if rect.contains(containerPoint) {
                hit = (range, checked)
                stop.pointee = true
            }
        }
        return hit
    }

    @objc private func handleCheckboxTap(_ gesture: UITapGestureRecognizer) {
        guard let (range, checked) = checkboxRange(at: gesture.location(in: self)) else { return }
        let text = (textStorage.string as NSString).substring(with: range)
        guard text.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil else { return }
        mdReplace(range, with: checked ? "[ ]" : "[x]")
        (delegate as? MarkdownUICoordinator)?.textChanged(self)
    }
}

extension MarkdownUITextView: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === checkboxTap {
            return checkboxRange(at: gestureRecognizer.location(in: self)) != nil
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

extension MarkdownUITextView: MarkdownLayoutHost {
    var mdBackingScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }
    var mdFont: PlatformFont? { font }
    var mdSelectedRanges: [NSRange] { [selectedRange] }

    func ensureVisibleLayout() {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
    }
}
#endif
