#if os(iOS) || os(visionOS)
//
//  MarkdownUICoordinator+Markers.swift
//  MarkdownEngine
//
//  Edit-menu items for the image or link at the selection: image size and
//  alignment, card size, and plain link vs preview card (the iOS side of
//  `ContextMenu+Markers.swift`).
//

import UIKit

extension MarkdownUICoordinator {

    public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                         suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let tv = textView as? MarkdownUITextView else { return nil }
        let elements = Self.markerMenuElements(for: tv, at: range.location)
        guard !elements.isEmpty else { return nil }
        return UIMenu(children: elements + suggestedActions)
    }

    static func markerMenuElements(for tv: MarkdownUITextView, at location: Int) -> [UIMenuElement] {
        guard tv.isEditable, let target = MarkdownAttributeEditing.target(at: location, in: tv.string) else { return [] }
        let start = target.range.location
        let kind = target.kind
        func action(_ title: String, _ marker: MarkerAction, on: Bool = false, image: String? = nil) -> UIAction {
            UIAction(title: EngineStrings.localized(title), image: image.flatMap { UIImage(systemName: $0) }, state: on ? .on : .off) { [weak tv] _ in
                tv?.applyMarkerAction(marker, at: start, kinds: [kind])
            }
        }
        let attributes = target.attributes
        let alignment = UIMenu(title: "Align", image: UIImage(systemName: "text.aligncenter"), children: [
            action("Left", .align(nil), on: (attributes.alignment ?? .left) == .left),
            action("Center", .align(.center), on: attributes.alignment == .center),
            action("Right", .align(.right), on: attributes.alignment == .right),
        ])
        switch kind {
        case .image:
            let sizes: [(String, MarkdownAttributes.Size?)] = [
                ("Original", nil), ("Icon", .icon), ("Small", .small), ("Medium", .medium), ("Large", .large), ("Full Width", .full),
            ]
            return [
                UIMenu(title: "Image Size", image: UIImage(systemName: "photo"),
                       children: sizes.map { action($0.0, .size($0.1), on: attributes.size == $0.1) }),
                alignment,
            ]
        case .link where target.isPreview:
            let current = attributes.size ?? .medium
            let sizes: [(String, MarkdownAttributes.Size)] = [("Icon Only", .icon), ("Small", .small), ("Medium", .medium), ("Large", .large)]
            return [
                UIMenu(title: "Card Size", image: UIImage(systemName: "rectangle.portrait"),
                       children: sizes.map { action($0.0, .size($0.1), on: current == $0.1) }),
                alignment,
                action("Show as Link", .preview(false), image: "link"),
            ]
        case .link, .bareURL:
            return [action("Show as Preview Card", .preview(true), image: "text.below.photo")]
        }
    }
}
#endif
