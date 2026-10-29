//
//  ContextMenu+Markers.swift
//  MarkdownEngine
//
//  Context-menu items for the image or link under the pointer: image size
//  and alignment, card size, and plain link vs preview card. They write the
//  `{…}` block (see `MarkdownAttributeEditing`).
//

#if os(macOS)
import AppKit

/// What a marker menu item applies, and where.
final class MarkerMenuPayload: NSObject {
    let action: MarkerAction
    let location: Int
    let kind: MarkdownAttributeTarget.Kind

    init(_ action: MarkerAction, location: Int, kind: MarkdownAttributeTarget.Kind) {
        self.action = action
        self.location = location
        self.kind = kind
    }
}

extension NativeTextViewWrapper.Coordinator {

    /// Items for the image / link at `charIndex`, ending with a separator; empty when there's none.
    func markerMenuItems(for textView: NSTextView, at charIndex: Int) -> [NSMenuItem] {
        guard textView.isEditable,
              let target = MarkdownAttributeEditing.target(at: charIndex, in: textView.string) else { return [] }
        let location = target.range.location
        func item(_ title: String, _ action: MarkerAction, on: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(didChooseMarkerItem(_:)), keyEquivalent: "")
            item.target = self
            item.image = MenuIcons.image(for: title)
            item.state = on ? .on : .off
            item.representedObject = MarkerMenuPayload(action, location: location, kind: target.kind)
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.image = MenuIcons.image(for: title)
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            parent.submenu = menu
            return parent
        }
        let attributes = target.attributes
        let alignment = submenu("Align", [
            item("Left", .align(nil), on: (attributes.alignment ?? .left) == .left),
            item("Center", .align(.center), on: attributes.alignment == .center),
            item("Right", .align(.right), on: attributes.alignment == .right),
        ])

        var items: [NSMenuItem] = []
        switch target.kind {
        case .image:
            let sizes: [(String, MarkdownAttributes.Size?)] = [
                ("Original", nil), ("Icon", .icon), ("Small", .small), ("Medium", .medium), ("Large", .large), ("Full Width", .full),
            ]
            items.append(submenu("Image Size", sizes.map { item($0.0, .size($0.1), on: attributes.size == $0.1) }))
            items.append(alignment)
        case .link where target.isPreview:
            let current = attributes.size ?? .medium
            let sizes: [(String, MarkdownAttributes.Size)] = [("Icon Only", .icon), ("Small", .small), ("Medium", .medium), ("Large", .large)]
            items.append(submenu("Card Size", sizes.map { item($0.0, .size($0.1), on: current == $0.1) }))
            items.append(alignment)
            items.append(item("Show as Link", .preview(false)))
        case .link, .bareURL:
            items.append(item("Show as Preview Card", .preview(true)))
        }
        items.append(.separator())
        return items
    }

    @objc func didChooseMarkerItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MarkerMenuPayload,
              let textView = textView as? NativeTextView else { return }
        textView.applyMarkerAction(payload.action, at: payload.location, kinds: [payload.kind])
    }
}

extension NativeTextView {

    /// Offers the "Preview Card" bar while the pointer rests on a plain link.
    func updateMarkerHover(with event: NSEvent) {
        guard isEditable, !markerBar.isPointerOverBar else { return }
        let point = convert(event.locationInWindow, from: nil)
        let target = linkCharacterIndex(at: point).flatMap {
            MarkdownAttributeEditing.target(at: $0, in: string, kinds: [.link])
        }
        markerBar.hover(over: target.flatMap { $0.isPreview ? nil : $0 })
    }

    /// The character under `viewPoint` when it carries a `.link`.
    private func linkCharacterIndex(at viewPoint: CGPoint) -> Int? {
        guard let tlm = textLayoutManager, let storage = textStorage, storage.length > 0,
              let tcs = tlm.textContentManager else { return nil }
        let containerPoint = CGPoint(x: viewPoint.x - textContainerOrigin.x, y: viewPoint.y - textContainerOrigin.y)
        guard let fragment = tlm.textLayoutFragment(for: containerPoint) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let inFragment = CGPoint(x: containerPoint.x - frame.minX, y: containerPoint.y - frame.minY)
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(inFragment) }) else { return nil }
        let inLine = CGPoint(x: inFragment.x - line.typographicBounds.minX, y: inFragment.y - line.typographicBounds.minY)
        let lineIndex = line.characterIndex(for: inLine)
        guard lineIndex >= 0, lineIndex < line.attributedString.length,
              line.attributedString.attribute(.link, at: lineIndex, effectiveRange: nil) != nil else { return nil }
        let fragmentStart = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location)
        // `characterIndex(for:)` is relative to the fragment, like `attributedString`.
        let index = fragmentStart + lineIndex
        return index < storage.length ? index : nil
    }
}
#endif
