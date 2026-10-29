//
//  MarkerBarTests.swift
//  MarkdownEngineTests
//
//  The image / link bar, the context-menu items and the controller API,
//  in a real (AppKit) editor.
//

#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MarkdownEngineCore

@MainActor
@Suite("Marker bar (AppKit)", .serialized)
struct MarkerBarTests {

    final class Box { var text: String; init(_ t: String) { text = t } }

    private struct Editor {
        let window: NSWindow
        let textView: NativeTextView
        let controller: MarkdownEditorController
        let box: Box
    }

    struct SwatchImages: ImageProvider {
        func image(for request: ImageRequest) -> PlatformImage? {
            NSImage(size: CGSize(width: 640, height: 360), flipped: false) { rect in
                NSGradient(starting: NSColor(red: 0.1, green: 0.5, blue: 0.6, alpha: 1),
                           ending: NSColor(red: 0.05, green: 0.2, blue: 0.35, alpha: 1))?.draw(in: rect, angle: -60)
                return true
            }
        }
        func fingerprint() -> AnyHashable { 1 }
    }

    private func makeEditor(_ text: String, images: Bool = false, size: CGSize = CGSize(width: 600, height: 400)) async throws -> Editor {
        _ = NSApplication.shared
        let box = Box(text)
        let controller = MarkdownEditorController()
        var configuration = MarkdownEditorConfiguration()
        if images { configuration.services.images = SwatchImages() }
        let root = NativeTextViewWrapper(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            configuration: configuration,
            fontName: "Helvetica", fontSize: 14, controller: controller
        )
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(0.5))
        func find(_ view: NSView) -> NativeTextView? {
            (view as? NativeTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let tv = try #require(find(window.contentView!))
        window.makeFirstResponder(tv)
        return Editor(window: window, textView: tv, controller: controller, box: box)
    }

    private func settle() async { try? await Task.sleep(for: .seconds(0.15)) }

    private let text = "Intro line\n\n![cat](cat.png)\n\nRead [Doc](https://a.com) now"

    @Test func barShowsForCaretInImageAndHidesWhenTyping() async throws {
        let e = try await makeEditor(text)
        defer { e.window.close() }
        let image = (text as NSString).range(of: "![cat]").location + 2
        e.textView.setSelectedRange(NSRange(location: image, length: 0))
        await settle()
        #expect(e.textView.markerBar.isVisible)
        #expect(e.textView.markerBar.target?.kind == .image)
        let host = try #require(e.textView.subviews.first { $0 is NSHostingView<MarkerBarView> })
        #expect(!host.isHidden)
        #expect(host.frame.width > 100 && host.frame.height > 20)

        e.textView.insertText("x", replacementRange: e.textView.selectedRange())
        await settle()
        #expect(!e.textView.markerBar.isVisible)

        // Plain prose: no bar.
        e.textView.setSelectedRange(NSRange(location: 2, length: 0))
        await settle()
        #expect(!e.textView.markerBar.isVisible)
    }

    @Test func barActionIsOneUndoableEditAndKeepsTheBar() async throws {
        let e = try await makeEditor(text)
        defer { e.window.close() }
        let image = (text as NSString).range(of: "![cat]").location + 2
        e.textView.setSelectedRange(NSRange(location: image, length: 0))
        await settle()
        #expect(e.textView.applyMarkerAction(.size(.small), at: image))
        #expect(e.textView.string.contains("![cat](cat.png){.small}\n"))
        #expect(e.textView.selectedRange().location == image)
        await settle()
        #expect(e.textView.markerBar.target?.attributes.size == .small)

        e.textView.applyMarkerAction(.align(.center), at: image)
        #expect(e.textView.string.contains("![cat](cat.png){.small .center}"))
        e.textView.undoManager?.undo()
        #expect(e.textView.string.contains("![cat](cat.png){.small}\n"))
        e.textView.undoManager?.undo()
        #expect(e.textView.string == text)
    }

    @Test func contextMenuOffersSizesAndPreviewToggle() async throws {
        let e = try await makeEditor(text)
        defer { e.window.close() }
        let coordinator = try #require(e.textView.delegate as? NativeTextViewWrapper.Coordinator)
        let image = (text as NSString).range(of: "cat.png").location
        let imageItems = coordinator.markerMenuItems(for: e.textView, at: image)
        #expect(imageItems.map(\.title) == ["Image Size", "Align", ""])
        let small = try #require(imageItems[0].submenu?.items.first { $0.title == "Small" })
        #expect(imageItems[0].submenu?.items.first { $0.title == "Original" }?.state == .on)
        coordinator.didChooseMarkerItem(small)
        #expect(e.textView.string.contains("![cat](cat.png){.small}"))

        let link = (e.textView.string as NSString).range(of: "[Doc]").location + 1
        let linkItems = coordinator.markerMenuItems(for: e.textView, at: link)
        #expect(linkItems.first?.title == "Show as Preview Card")
        coordinator.didChooseMarkerItem(linkItems[0])
        #expect(e.textView.string.hasSuffix("[Doc](https://a.com){.preview} now"))

        let card = coordinator.markerMenuItems(for: e.textView, at: link)
        #expect(card.map(\.title) == ["Card Size", "Align", "Show as Link", ""])
        #expect(coordinator.markerMenuItems(for: e.textView, at: 2).isEmpty)
    }

    @Test func controllerAPI() async throws {
        let e = try await makeEditor(text)
        defer { e.window.close() }
        let link = (text as NSString).range(of: "[Doc]").location + 2
        e.textView.setSelectedRange(NSRange(location: link, length: 0))
        #expect(e.controller.attributeTarget?.kind == .link)
        #expect(!e.controller.setImageSize(.large))          // not an image
        #expect(!e.controller.setLinkCardSize(.large))       // not a card yet
        #expect(e.controller.setLinkPreview(true))
        #expect(e.controller.setLinkCardSize(.large))
        #expect(e.controller.setAlignment(.right))
        #expect(e.textView.string.hasSuffix("[Doc](https://a.com){.preview .large .right} now"))
        #expect(e.controller.setLinkPreview(false))
        #expect(e.textView.string.hasSuffix("[Doc](https://a.com){.right} now"))
        // The binding follows.
        await settle()
        #expect(e.box.text == e.textView.string)
    }

    @Test func snapshotInTheEditor() async throws {
        let text = "Intro line\n\n![cat](cat.png){.small .center}\n\nRead [Doc](https://a.com) now"
        let e = try await makeEditor(text, images: true, size: CGSize(width: 560, height: 420))
        defer { e.window.close() }
        e.window.contentView?.appearance = NSAppearance(named: .aqua)
        let image = (text as NSString).range(of: "![cat]").location + 2
        e.textView.setSelectedRange(NSRange(location: image, length: 0))
        try? await Task.sleep(for: .seconds(0.4))
        #expect(e.textView.markerBar.isVisible)
        let view = try #require(e.window.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: "/tmp/eng-markers-shots", withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/eng-markers-shots/editor-image.png"))
    }

    @Test func snapshotOfTheBars() async throws {
        let shots = URL(fileURLWithPath: "/tmp/eng-markers-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let modes: [(String, MarkdownAttributeTarget)] = [
            ("image", MarkdownAttributeEditing.target(at: 2, in: "![](a.png){.medium .center}")!),
            ("card", MarkdownAttributeEditing.target(at: 2, in: "[a](https://a.com){.preview}")!),
            ("link", MarkdownAttributeEditing.target(at: 2, in: "[a](https://a.com)")!),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let stack = VStack(alignment: .leading, spacing: 12) {
                ForEach(modes, id: \.0) { mode in
                    MarkerBarView(content: .init(mode.1), tint: Color(red: 0.1, green: 0.56, blue: 0.66)) { _ in }
                }
            }
            .padding(16)
            .background(Color(nsColor: .textBackgroundColor))
            let host = NSHostingView(rootView: stack)
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(0.3))
            host.frame.size = host.fittingSize
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let name = appearance == .aqua ? "bars-light.png" : "bars-dark.png"
            try rep.representation(using: .png, properties: [:])?.write(to: shots.appendingPathComponent(name))
            window.close()
        }
    }
}
#endif
