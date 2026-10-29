//
//  SwiftMathBridge.swift
//  MarkdownEngineLatex
//
//  Ready-made LatexRenderer conformance backed by SwiftMath.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import SwiftMath
import MarkdownEngineCore

/// A drop-in ``LatexRenderer`` backed by [SwiftMath].
///
/// Renders both block (`$$ … $$`) and inline (`$ … $`) LaTeX strings into
/// `PlatformImage`s using the Latin Modern math font. Results are cached per
/// (latex, font size, appearance, theme color fingerprint) so repeated
/// renders are free.
///
/// Light/dark appearance is taken from the host editor's window
/// effective appearance, not from `NSApp.effectiveAppearance`, so apps
/// that force a light window when the system is in dark mode still get
/// correctly-tinted formulas.
///
/// [SwiftMath]: https://github.com/mgriebling/SwiftMath
public final class SwiftMathBridge: LatexRenderer, @unchecked Sendable {
    private struct CacheKey: Hashable {
        let latex: String
        let fontSize: CGFloat
        let isDarkMode: Bool
        let lightColorRGB: UInt32
        let darkColorRGB: UInt32
    }

    private struct CacheEntry {
        let image: PlatformImage
        let size: CGSize
        let baselineOffset: CGFloat
    }

    private let singleLetterPaddingBottom: CGFloat
    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheLock = NSLock()

    /// - Parameter singleLetterPaddingBottom: Extra bottom padding (in
    ///   points) added to single-letter formulas to prevent visual
    ///   clipping; matches the engine's
    ///   ``MarkdownEditorConfiguration/blockLatex/singleLetterPaddingBottom``
    ///   default. Override to match a customized configuration.
    public init(singleLetterPaddingBottom: CGFloat = 1.0) {
        self.singleLetterPaddingBottom = singleLetterPaddingBottom
    }

    /// Clears the rendered-image cache. Call after appearance flips if
    /// the host code doesn't re-render formulas automatically.
    public func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - LatexRenderer

    public func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        let normalizedLatex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLatex.isEmpty else { return nil }

        let isDarkMode = MarkdownPlatform.isDarkAppearance
        let textColor = isDarkMode ? theme.latexDarkModeText : theme.latexLightModeText
        let key = CacheKey(
            latex: normalizedLatex,
            fontSize: fontSize,
            isDarkMode: isDarkMode,
            lightColorRGB: Self.colorFingerprint(theme.latexLightModeText),
            darkColorRGB: Self.colorFingerprint(theme.latexDarkModeText)
        )

        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return LatexRenderResult(
                image: cached.image,
                size: cached.size,
                baselineOffset: cached.baselineOffset
            )
        }
        cacheLock.unlock()

        guard let entry = renderLatex(normalizedLatex, fontSize: fontSize, textColor: textColor) else {
            return nil
        }

        cacheLock.lock()
        cache[key] = entry
        cacheLock.unlock()

        return LatexRenderResult(
            image: entry.image,
            size: entry.size,
            baselineOffset: entry.baselineOffset
        )
    }

    // MARK: - Private

    /// Fold an `PlatformColor` to a 24-bit fingerprint that's good enough to
    /// bust the cache when the theme changes the LaTeX text color.
    private static func colorFingerprint(_ color: PlatformColor) -> UInt32 {
        guard let rgb = MarkdownPlatform.rgb(color) else { return 0 }
        let r = UInt32(max(0, min(255, Int(rgb.r * 255))))
        let g = UInt32(max(0, min(255, Int(rgb.g * 255))))
        let b = UInt32(max(0, min(255, Int(rgb.b * 255))))
        return (r << 16) | (g << 8) | b
    }

    private func renderLatex(_ latex: String, fontSize: CGFloat, textColor: PlatformColor) -> CacheEntry? {
        let mathLabel = MTMathUILabel()
        mathLabel.latex = latex
        mathLabel.fontSize = fontSize
        mathLabel.textColor = textColor
        mathLabel.textAlignment = .left
        mathLabel.labelMode = .text

        // Latin Modern Math gives the cleanest LaTeX glyphs at typical sizes.
        if let mathFont = MTFontManager().font(withName: "latinmodern-math", size: fontSize) {
            mathLabel.font = mathFont
        }

        #if os(macOS)
        mathLabel.layoutSubtreeIfNeeded()
        #else
        mathLabel.layoutIfNeeded()
        #endif

        guard let displayList = mathLabel.displayList else { return nil }

        // SwiftMath skips unsupported glyphs (e.g. emoji/raw Greek), which can yield
        // zero-sized output. Bail instead of trying to render a 0x0 image — lockFocus
        // (used internally by PlatformImage drawing) crashes on zero dimensions.
        let exactWidth = displayList.width
        let exactHeight = displayList.ascent + displayList.descent
        guard exactWidth > 0, exactHeight > 0 else { return nil }

        let isSimpleSingleLetter = latex.range(of: #"^[A-Za-z]{1,3}$"#, options: .regularExpression) != nil
        let paddingBottom: CGFloat = isSimpleSingleLetter ? singleLetterPaddingBottom : 0
        let canvasHeight = exactHeight + paddingBottom

        // `displayList.width` is the advance width, which excludes the right-side ink
        // overhang of slanted glyphs (V, Y, P, F, …) — cropping to it clips them.
        // Render with right slack, then crop to the measured ink edge.
        let rightSlack = ceil(fontSize)
        let probeWidth = ceil(exactWidth) + rightSlack

        guard let probeCG = renderLabelToCGImage(mathLabel, size: CGSize(width: probeWidth, height: canvasHeight)) else {
            return nil
        }

        let inkRight = Self.inkRightEdge(probeCG, widthInPoints: probeWidth) ?? exactWidth
        let finalWidth = max(ceil(exactWidth), ceil(inkRight))
        let finalSize = CGSize(width: finalWidth, height: canvasHeight)

        // Crop to the measured width (full height kept); points→pixels via the rep,
        // so this is correct at any backing scale.
        let pxPerPoint = CGFloat(probeCG.width) / probeWidth
        let cropPx = min(probeCG.width, Int((finalWidth * pxPerPoint).rounded()))
        guard cropPx > 0,
              let croppedCG = probeCG.cropping(to: CGRect(x: 0, y: 0, width: cropPx, height: probeCG.height)) else {
            return nil
        }

        let image = Self.makeImage(croppedCG, size: finalSize, scale: pxPerPoint)

        return CacheEntry(
            image: image,
            size: finalSize,
            baselineOffset: displayList.descent
        )
    }

    private func renderLabelToCGImage(_ label: MTMathUILabel, size: CGSize) -> CGImage? {
        #if os(macOS)
        // `bitmapImageRepForCachingDisplay` + `cacheDisplay(in:to:)` is the
        // documented way to snapshot an NSView that isn't in a window. Setting
        // `wantsLayer = true` and `layer.render(in:)` snapshots the (empty)
        // backing layer instead of triggering MTMathUILabel's `draw(_:)`.
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()

        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        return rep.cgImage
        #else
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            // The label draws in CoreText (y-up) coordinates and relies on
            // `layer.geometryFlipped`, which `render(in:)` ignores off-screen.
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            label.layer.render(in: ctx.cgContext)
        }.cgImage
        #endif
    }

    private static func makeImage(_ cgImage: CGImage, size: CGSize, scale: CGFloat) -> PlatformImage {
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let image = PlatformImage(size: size)
        image.addRepresentation(rep)
        return image
        #else
        return PlatformImage(cgImage: cgImage, scale: scale, orientation: .up)
        #endif
    }

    /// Right-most x (in points) containing non-transparent ink, or `nil` if empty —
    /// lets us crop a formula to its true ink width instead of the advance width.
    private static func inkRightEdge(_ image: CGImage, widthInPoints: CGFloat) -> CGFloat? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0, widthInPoints > 0 else { return nil }

        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &data, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Scan each row from the right, stopping once we pass the running max.
        var maxX = -1
        for y in 0..<h {
            let row = y * bytesPerRow
            var x = w - 1
            while x > maxX {
                if data[row + x * 4 + 3] > 10 { maxX = x; break }
                x -= 1
            }
        }
        guard maxX >= 0 else { return nil }

        // +1: pixel `maxX` spans [maxX, maxX+1). Convert to points.
        return (CGFloat(maxX) + 1) * widthInPoints / CGFloat(w)
    }
}
