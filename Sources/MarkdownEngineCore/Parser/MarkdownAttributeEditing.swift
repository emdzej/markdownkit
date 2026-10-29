//
//  MarkdownAttributeEditing.swift
//  MarkdownEngine
//
//  Finds the image or link at a location and rewrites its `{…}` attribute
//  block (size, alignment, preview card). Pure text logic, shared by the
//  context menus, the floating image/link bar and `MarkdownEditorController`.
//

import Foundation

/// An image, a link or a bare URL in the source, with its attribute block.
public struct MarkdownAttributeTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case image, link, bareURL }

    public let kind: Kind
    /// The construct without its attribute block: `![alt](url)`, `[text](url)`, `https://…`.
    public let range: NSRange
    /// The `{…}` block right after it, if any.
    public let attributesRange: NSRange?
    public let attributes: MarkdownAttributes
    public let destination: String

    /// The construct including its attribute block.
    public var fullRange: NSRange {
        guard let attributesRange else { return range }
        return NSRange(location: range.location, length: NSMaxRange(attributesRange) - range.location)
    }

    /// Whether a link renders as a card (or icon) rather than plain text.
    public var isPreview: Bool { kind == .link && attributes.wantsPreview }
}

/// A text replacement, plus where the edited construct ends up.
public struct MarkdownAttributeEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    /// The edited construct (with its attribute block) after the edit.
    public let resultRange: NSRange
}

public enum MarkdownAttributeEditing {

    /// The innermost image or link whose source contains `location` (its end
    /// counts, so a caret right after `)` or `}` finds it); a bare URL when
    /// there's neither. `kinds` limits what's looked for.
    public static func target(
        at location: Int,
        in text: String,
        kinds: Set<MarkdownAttributeTarget.Kind> = [.image, .link, .bareURL]
    ) -> MarkdownAttributeTarget? {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(location, max(ns.length - 1, 0)), length: 0))
        let content = trimmingNewline(line, in: ns)
        guard content.length > 0 else { return nil }

        var best: MarkdownAttributeTarget?
        func visit(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .image(let range, _, let url, let markers):
                    guard kinds.contains(.image), contains(range, location) else { continue }
                    best = make(.image, range: range, url: url, markers: markers, ns: ns)
                case .link(let range, _, let url, let markers, let children):
                    guard contains(range, location) else { continue }
                    if kinds.contains(.link) { best = make(.link, range: range, url: url, markers: markers, ns: ns) }
                    visit(children)
                case .emphasis(_, let range, _, let children), .strikethrough(let range, _, let children):
                    if contains(range, location) { visit(children) }
                default:
                    continue
                }
            }
        }
        let nodes = InlineParser.parse(ns, range: content)
        visit(nodes)
        if let best { return best }
        guard kinds.contains(.bareURL) else { return nil }
        return bareURL(at: location, in: ns, line: content, nodes: nodes)
    }

    /// The edit that applies `change` to the target's attributes. A bare URL
    /// becomes `[url](url){…}` when the change leaves attributes. nil when
    /// nothing would change.
    public static func edit(
        _ target: MarkdownAttributeTarget,
        change: (inout MarkdownAttributes) -> Void
    ) -> MarkdownAttributeEdit? {
        var attributes = target.attributes
        change(&attributes)
        guard attributes != target.attributes else { return nil }
        let block = attributes.markdown()

        switch target.kind {
        case .image, .link:
            let range = target.attributesRange ?? NSRange(location: NSMaxRange(target.range), length: 0)
            let result = NSRange(location: target.range.location,
                                 length: target.range.length + (block as NSString).length)
            return MarkdownAttributeEdit(range: range, replacement: block, resultRange: result)
        case .bareURL:
            guard !block.isEmpty else { return nil }
            let link = "[\(target.destination)](\(target.destination))" + block
            return MarkdownAttributeEdit(range: target.range, replacement: link,
                                         resultRange: NSRange(location: target.range.location, length: (link as NSString).length))
        }
    }

    // MARK: - Common changes

    public static func setSize(_ size: MarkdownAttributes.Size?) -> (inout MarkdownAttributes) -> Void {
        { $0.setSize(size) }
    }

    public static func setAlignment(_ alignment: MarkdownAttributes.Alignment?) -> (inout MarkdownAttributes) -> Void {
        { $0.setAlignment(alignment) }
    }

    public static func setPreview(_ on: Bool) -> (inout MarkdownAttributes) -> Void {
        { $0.setPreview(on) }
    }

    // MARK: - Helpers

    private static func make(_ kind: MarkdownAttributeTarget.Kind, range: NSRange, url: NSRange,
                             markers: [NSRange], ns: NSString) -> MarkdownAttributeTarget? {
        guard markers.count >= 4 else { return nil }
        let base = NSRange(location: range.location, length: NSMaxRange(markers[3]) - range.location)
        let attributesRange = markers.count > 4 ? markers[4] : nil
        let attributes = attributesRange.flatMap { MarkdownAttributes(source: ns.substring(with: $0)) } ?? MarkdownAttributes()
        return MarkdownAttributeTarget(kind: kind, range: base, attributesRange: attributesRange,
                                       attributes: attributes, destination: ns.substring(with: url))
    }

    private static func bareURL(at location: Int, in ns: NSString, line: NSRange, nodes: [InlineNode]) -> MarkdownAttributeTarget? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let claimed = nodes.compactMap { node -> NSRange? in
            switch node {
            case .code(let r, _), .link(let r, _, _, _, _), .image(let r, _, _, _), .inlineLatex(let r, _, _): return r
            default: return nil
            }
        }
        for match in detector.matches(in: ns as String, range: line) where contains(match.range, location) {
            guard !claimed.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let source = ns.substring(with: match.range)
            // Only what's written as a web address, not "foo.com" inside prose or emails.
            guard source.hasPrefix("http://") || source.hasPrefix("https://") || source.hasPrefix("www.") else { continue }
            return MarkdownAttributeTarget(kind: .bareURL, range: match.range, attributesRange: nil,
                                           attributes: MarkdownAttributes(), destination: source)
        }
        return nil
    }

    private static func contains(_ range: NSRange, _ location: Int) -> Bool {
        location >= range.location && location <= NSMaxRange(range)
    }

    private static func trimmingNewline(_ line: NSRange, in ns: NSString) -> NSRange {
        var length = line.length
        while length > 0 {
            let c = ns.character(at: line.location + length - 1)
            guard c == 0x0A || c == 0x0D else { break }
            length -= 1
        }
        return NSRange(location: line.location, length: length)
    }
}

extension MarkdownAttributes {

    /// Replaces any alignment keyword with `alignment` (nil clears it).
    public mutating func setAlignment(_ alignment: Alignment?) {
        items.removeAll { if case .class(let c) = $0 { return Alignment(rawValue: c) != nil } else { return false } }
        if let alignment { items.append(.class(alignment.rawValue)) }
    }

    /// Turns a link's preview card on (`.preview`) or off (also drops sizes,
    /// which imply a card). Other entries are kept.
    public mutating func setPreview(_ on: Bool) {
        if on {
            if !wantsPreview { items.append(.class("preview")) }
        } else {
            setSize(nil)
            items.removeAll { $0 == .class("preview") }
        }
    }
}
