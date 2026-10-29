//
//  Platform.swift
//  MarkdownEngine
//
//  Cross-platform type aliases. Everything outside `TextView/` is written
//  against these so the parser, styler, and renderer compile for both
//  AppKit (macOS) and UIKit (iOS / iPadOS).
//

#if os(macOS)
import AppKit

public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
public typealias PlatformFontDescriptor = NSFontDescriptor
public typealias PlatformBezierPath = NSBezierPath
public typealias PlatformTextView = NSTextView
#else
import UIKit

public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
public typealias PlatformFontDescriptor = UIFontDescriptor
public typealias PlatformBezierPath = UIBezierPath
public typealias PlatformTextView = UITextView
#endif

// MARK: - Appearance

#if os(macOS)
public typealias PlatformAppearance = NSAppearance
#else
public typealias PlatformAppearance = UITraitCollection
#endif

extension PlatformAppearance {
    /// The appearance the app is currently drawing with.
    static var mdCurrent: PlatformAppearance {
        #if os(macOS)
        NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        #else
        UITraitCollection.current
        #endif
    }

    func mdPerformAsCurrent(_ block: () -> Void) {
        #if os(macOS)
        performAsCurrentDrawingAppearance(block)
        #else
        performAsCurrent(block)
        #endif
    }
}

extension PlatformColor {
    /// Resolves a dynamic (light/dark) color to concrete sRGB components
    /// under `appearance`, so `withAlphaComponent` doesn't freeze the wrong variant.
    func mdResolved(in appearance: PlatformAppearance) -> PlatformColor {
        #if os(macOS)
        var resolved: PlatformColor = self
        appearance.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB) ?? self
        }
        return resolved
        #else
        return resolvedColor(with: appearance)
        #endif
    }

    // Semantic system colors under one name on both platforms.
    #if os(macOS)
    public static var mdLabel: PlatformColor { .labelColor }
    public static var mdSecondaryLabel: PlatformColor { .secondaryLabelColor }
    public static var mdTertiaryLabel: PlatformColor { .tertiaryLabelColor }
    public static var mdLink: PlatformColor { .linkColor }
    #else
    public static var mdLabel: PlatformColor { .label }
    public static var mdSecondaryLabel: PlatformColor { .secondaryLabel }
    public static var mdTertiaryLabel: PlatformColor { .tertiaryLabel }
    public static var mdLink: PlatformColor { .link }
    #endif
}

// MARK: - Drawing

extension PlatformImage {
    /// Draws an image in a top-left-origin (flipped) coordinate space on both platforms.
    static func mdDrawing(size: CGSize, _ draw: @escaping () -> Void) -> PlatformImage {
        #if os(macOS)
        return NSImage(size: size, flipped: true) { _ in draw(); return true }
        #else
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw() }
        #endif
    }
}

#if os(iOS) || os(visionOS)
extension UIBezierPath {
    /// AppKit spelling, so path-building code is shared.
    func line(to point: CGPoint) { addLine(to: point) }
}
#endif

// MARK: - Text view

/// Implemented by each platform's coordinator so shared input handlers can
/// suppress restyle/binding feedback while they mutate the text.
protocol ProgrammaticEditTracking: AnyObject {
    var isProgrammaticEdit: Bool { get set }
}

extension PlatformTextView {
    #if os(iOS) || os(visionOS)
    /// AppKit spelling of the full document text.
    var string: String { text ?? "" }

    func setSelectedRange(_ range: NSRange) { selectedRange = range }

    /// UIScrollView's bounds are its visible rect.
    var visibleRect: CGRect { bounds }
    #endif

    /// Text storage as an optional on both platforms (non-optional on UIKit).
    var mdTextStorage: NSTextStorage? { textStorage }

    var mdEditTracker: ProgrammaticEditTracking? { delegate as? ProgrammaticEditTracking }

    /// Replaces `range` with `string` as a single undoable user-level edit,
    /// flagged as programmatic for the coordinator.
    func mdReplace(_ range: NSRange, with string: String) {
        let tracker = mdEditTracker
        tracker?.isProgrammaticEdit = true
        defer { tracker?.isProgrammaticEdit = false }
        #if os(macOS)
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
        #else
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        replace(textRange, withText: string)
        #endif
    }
}

// MARK: - Fonts

#if os(iOS) || os(visionOS)
extension UIFontDescriptor.SymbolicTraits {
    // AppKit spellings, so trait code is shared.
    static let bold: Self = .traitBold
    static let italic: Self = .traitItalic
    static let monoSpace: Self = .traitMonoSpace
}
#endif

extension PlatformFont {
    /// `descriptor` with its symbolic traits replaced by `traits`; nil if the
    /// family has no such face.
    static func md(descriptor: PlatformFontDescriptor, traits: PlatformFontDescriptor.SymbolicTraits, size: CGFloat) -> PlatformFont? {
        #if os(macOS)
        return PlatformFont(descriptor: descriptor.withSymbolicTraits(traits), size: size)
        #else
        guard let d = descriptor.withSymbolicTraits(traits) else { return nil }
        return PlatformFont(descriptor: d, size: size)
        #endif
    }
}

// MARK: - Attribute keys and values

#if os(iOS) || os(visionOS)
extension NSAttributedString.Key {
    /// AppKit's spelling-state key. UIKit has no equivalent; the attribute is
    /// inert there but keeps the styler's output identical across platforms.
    static let spellingState = NSAttributedString.Key("NSSpellingState")
}
#endif

extension NSValue {
    convenience init(mdRect rect: CGRect) {
        #if os(macOS)
        self.init(rect: rect)
        #else
        self.init(cgRect: rect)
        #endif
    }

    var mdRect: CGRect {
        #if os(macOS)
        rectValue
        #else
        cgRectValue
        #endif
    }
}

extension PlatformColor {
    #if os(macOS)
    public static var mdTextBackground: PlatformColor { .textBackgroundColor }
    #else
    public static var mdTextBackground: PlatformColor { .systemBackground }
    #endif

    /// sRGB components, or nil for pattern / non-convertible colors.
    var mdRGB: (r: CGFloat, g: CGFloat, b: CGFloat)? {
        #if os(macOS)
        guard let c = usingColorSpace(.deviceRGB) else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        return getRed(&r, green: &g, blue: &b, alpha: &a) ? (r, g, b) : nil
        #endif
    }
}

// MARK: - Layout host

/// What the layout fragment and styler need from the editor's text view.
/// Implemented by `NativeTextView` (AppKit) and `MarkdownUITextView` (UIKit).
protocol MarkdownLayoutHost: AnyObject {
    var configuration: MarkdownEditorConfiguration { get }
    var baseFont: PlatformFont { get }
    var layoutBridge: LayoutBridge? { get }
    /// Device pixels per point for pixel-snapping.
    var mdBackingScale: CGFloat { get }
    /// The text view's base font (`font` property).
    var mdFont: PlatformFont? { get }
    var mdSelectedRanges: [NSRange] { get }
    /// Forces TextKit 2 to lay out the visible viewport now.
    func ensureVisibleLayout()
}

#if os(iOS) || os(visionOS)
private final class WeakLayoutHost {
    weak var host: MarkdownLayoutHost?
    init(_ host: MarkdownLayoutHost?) { self.host = host }
}
nonisolated(unsafe) private var mdHostKey: UInt8 = 0
#endif

extension NSTextLayoutManager {
    #if os(macOS)
    /// The editor view driving this layout manager, if any.
    var mdHost: MarkdownLayoutHost? { textContainer?.textView as? MarkdownLayoutHost }
    #else
    /// The editor view driving this layout manager, if any. UIKit text
    /// containers have no view back-pointer, so the view registers itself.
    var mdHost: MarkdownLayoutHost? {
        get { (objc_getAssociatedObject(self, &mdHostKey) as? WeakLayoutHost)?.host }
        set { objc_setAssociatedObject(self, &mdHostKey, WeakLayoutHost(newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    #endif
}

// MARK: - Graphics context

/// Makes `cgContext` the current platform drawing context (flipped on macOS,
/// natively top-left on UIKit) so NSString/NSImage/UIImage drawing lands in it.
func mdPushGraphicsContext(_ cgContext: CGContext) {
    #if os(macOS)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: true)
    #else
    UIGraphicsPushContext(cgContext)
    #endif
}

func mdPopGraphicsContext() {
    #if os(macOS)
    NSGraphicsContext.restoreGraphicsState()
    #else
    UIGraphicsPopContext()
    #endif
}

extension PlatformImage {
    static func mdSymbol(_ name: String) -> PlatformImage? {
        #if os(macOS)
        PlatformImage(systemSymbolName: name, accessibilityDescription: nil)
        #else
        PlatformImage(systemName: name)
        #endif
    }
}

extension PlatformImage {
    func mdApplying(_ config: PlatformImage.SymbolConfiguration) -> PlatformImage? {
        #if os(macOS)
        withSymbolConfiguration(config)
        #else
        applyingSymbolConfiguration(config)
        #endif
    }
}

// MARK: - Public helpers for bridge modules

public enum MarkdownPlatform {
    /// Whether the app is currently drawing in a dark appearance.
    public static var isDarkAppearance: Bool {
        #if os(macOS)
        let appearance = NSApp?.keyWindow?.effectiveAppearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
        return UITraitCollection.current.userInterfaceStyle == .dark
        #endif
    }

    /// 0–1 sRGB components of `color`, or nil if it can't be converted.
    public static func rgb(_ color: PlatformColor) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        color.mdRGB
    }
}
