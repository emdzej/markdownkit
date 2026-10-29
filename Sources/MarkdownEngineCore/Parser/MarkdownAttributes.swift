//
//  MarkdownAttributes.swift
//  MarkdownEngine
//
//  A `{…}` attribute block directly after an image or a link, e.g.
//  `![](a.png){.small .center}` or `[Doc](a.pdf){.preview width=320}`.
//  Pandoc-style syntax: `.class`, `#id`, `key=value`, `key="quoted value"`.
//  Unknown entries are kept (in order) and ignored by the renderer.
//

import CoreGraphics
import Foundation

public struct MarkdownAttributes: Equatable, Sendable {

    public enum Item: Equatable, Sendable {
        case `class`(String)
        case id(String)
        case pair(key: String, value: String)
    }

    /// Display size keyword (`.icon`, `.small`, `.medium`, `.large`, `.full`).
    public enum Size: String, CaseIterable, Sendable {
        case icon, small, medium, large, full
    }

    public enum Alignment: String, CaseIterable, Sendable {
        case left, center, right
    }

    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    /// Parses a full block including the braces; nil if it isn't valid attribute syntax.
    public init?(source: String) {
        guard source.hasPrefix("{"), source.hasSuffix("}"), source.count >= 2 else { return nil }
        guard let items = Self.parseItems(String(source.dropFirst().dropLast())) else { return nil }
        self.items = items
    }

    public var classes: [String] {
        items.compactMap { if case .class(let c) = $0 { return c } else { return nil } }
    }

    public func value(for key: String) -> String? {
        for case .pair(let k, let v) in items.reversed() where k == key { return v }
        return nil
    }

    /// The last size keyword wins.
    public var size: Size? { classes.reversed().lazy.compactMap(Size.init(rawValue:)).first }

    public var alignment: Alignment? { classes.reversed().lazy.compactMap(Alignment.init(rawValue:)).first }

    public var width: CGFloat? { value(for: "width").flatMap(Self.points) }
    public var height: CGFloat? { value(for: "height").flatMap(Self.points) }

    /// A link renders as a preview card: `.preview`, or any size.
    public var wantsPreview: Bool { classes.contains("preview") || size != nil || width != nil || height != nil }

    /// Replaces any size keyword and `width` / `height` with `size` (nil clears them).
    public mutating func setSize(_ size: Size?) {
        items.removeAll { item in
            switch item {
            case .class(let c): return Size(rawValue: c) != nil
            case .pair(let k, _): return k == "width" || k == "height"
            case .id: return false
            }
        }
        if let size { items.append(.class(size.rawValue)) }
    }

    /// The block as markdown (`{.small width=320}`), or "" when empty.
    public func markdown() -> String {
        guard !items.isEmpty else { return "" }
        let parts = items.map { item -> String in
            switch item {
            case .class(let c): return ".\(c)"
            case .id(let i): return "#\(i)"
            case .pair(let k, let v):
                let bare = !v.isEmpty && v.unicodeScalars.allSatisfy { Self.isValueChar($0) }
                return bare ? "\(k)=\(v)" : "\(k)=\"\(v.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
        }
        return "{" + parts.joined(separator: " ") + "}"
    }

    // MARK: - Parsing

    private static func parseItems(_ body: String) -> [Item]? {
        let scalars = Array(body.unicodeScalars)
        var items: [Item] = []
        var i = 0
        func skipSpace() { while i < scalars.count, scalars[i] == " " || scalars[i] == "\t" { i += 1 } }
        func name() -> String {
            var s = String.UnicodeScalarView()
            while i < scalars.count, isNameChar(scalars[i]) { s.append(scalars[i]); i += 1 }
            return String(s)
        }
        skipSpace()
        while i < scalars.count {
            switch scalars[i] {
            case ".", "#":
                let isClass = scalars[i] == "."
                i += 1
                let n = name()
                guard !n.isEmpty else { return nil }
                items.append(isClass ? .class(n) : .id(n))
            default:
                let key = name()
                guard !key.isEmpty, i < scalars.count, scalars[i] == "=" else { return nil }
                i += 1
                var value = String.UnicodeScalarView()
                if i < scalars.count, scalars[i] == "\"" {
                    i += 1
                    var closed = false
                    while i < scalars.count {
                        if scalars[i] == "\\", i + 1 < scalars.count { value.append(scalars[i + 1]); i += 2; continue }
                        if scalars[i] == "\"" { closed = true; i += 1; break }
                        value.append(scalars[i]); i += 1
                    }
                    guard closed else { return nil }
                } else {
                    while i < scalars.count, isValueChar(scalars[i]) { value.append(scalars[i]); i += 1 }
                    guard !value.isEmpty else { return nil }
                }
                items.append(.pair(key: key, value: String(value)))
            }
            // Entries are separated by whitespace.
            guard i == scalars.count || scalars[i] == " " || scalars[i] == "\t" else { return nil }
            skipSpace()
        }
        return items
    }

    private static func isNameChar(_ c: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_" || c == ":"
    }

    private static func isValueChar(_ c: Unicode.Scalar) -> Bool {
        !CharacterSet.whitespacesAndNewlines.contains(c) && c != "\"" && c != "{" && c != "}" && c != "="
    }

    /// `320` or `320px`; positive only.
    private static func points(_ value: String) -> CGFloat? {
        let digits = value.hasSuffix("px") ? String(value.dropLast(2)) : value
        guard let n = Double(digits), n > 0, n.isFinite else { return nil }
        return CGFloat(n)
    }
}
