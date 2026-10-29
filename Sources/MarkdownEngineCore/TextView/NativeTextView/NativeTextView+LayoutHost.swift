#if os(macOS)
//
//  NativeTextView+LayoutHost.swift
//  MarkdownEngine
//

import AppKit

extension NativeTextView: MarkdownLayoutHost {
    var mdBackingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    var mdFont: PlatformFont? { font }

    var mdSelectedRanges: [NSRange] { selectedRanges.map(\.rangeValue) }
}
#endif
