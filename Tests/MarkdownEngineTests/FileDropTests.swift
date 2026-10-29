//
//  FileDropTests.swift
//  MarkdownEngineTests
//
//  Dropped-file links, and (macOS) the drop hook inserting the embedder's
//  markdown at the drop point as one undoable edit.
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MarkdownEngineCore

@Suite("Dropped file links")
struct DroppedFileLinkTests {

    @Test func imagesBecomeImageLinks() {
        let file = DroppedFile(url: URL(fileURLWithPath: "/tmp/Photo 1.JPG"))
        #expect(file.isImage)
        #expect(file.markdownLink(to: "_attachments/Idea/Photo 1.JPG") == "![](_attachments/Idea/Photo%201.JPG)")
    }

    @Test func otherFilesBecomeNamedLinks() {
        let file = DroppedFile(url: URL(fileURLWithPath: "/tmp/Q3 (final).pdf"))
        #expect(!file.isImage)
        #expect(file.markdownLink(to: "_attachments/Q3 (final).pdf") == "[Q3 (final).pdf](_attachments/Q3%20%28final%29.pdf)")
    }

    @Test func bracketsInNamesAreEscaped() {
        let file = DroppedFile(url: URL(fileURLWithPath: "/tmp/a.zip"), contentType: .zip, name: "[draft] a.zip")
        #expect(file.markdownLink(to: "a.zip") == "[\\[draft\\] a.zip](a.zip)")
    }

    @Test func explicitTypeWinsOverExtension() {
        let file = DroppedFile(url: URL(fileURLWithPath: "/tmp/blob"), contentType: .png)
        #expect(file.isImage)
        #expect(file.name == "blob")
    }
}

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
@Suite("File drop (AppKit)", .serialized)
struct FileDropAppKitTests {

    final class Box { var text: String; init(_ t: String) { text = t } }

    @Test func dropInsertsHandlerMarkdownAtTheDropPointAsOneUndoStep() async throws {
        _ = NSApplication.shared
        let box = Box("Before\nAfter")
        var received: [DroppedFile] = []
        let root = NativeTextViewWrapper(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            fontName: "Helvetica", fontSize: 14,
            onDropFiles: { files in
                received = files
                return files.map { $0.markdownLink(to: "_attachments/\($0.name)") }.joined(separator: "\n")
            }
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        defer { window.close() }
        try? await Task.sleep(for: .seconds(0.5))

        func find(_ view: NSView) -> NativeTextView? {
            (view as? NativeTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let tv = try #require(find(window.contentView!))
        let files = [
            DroppedFile(url: URL(fileURLWithPath: "/tmp/cat.png")),
            DroppedFile(url: URL(fileURLWithPath: "/tmp/notes.pdf")),
        ]
        tv.insertDroppedFiles(files, at: ("Before\n" as NSString).length)
        try? await Task.sleep(for: .seconds(0.4))

        #expect(received == files)
        #expect(box.text == "Before\n![](_attachments/cat.png)\n[notes.pdf](_attachments/notes.pdf)After")
        #expect(tv.undoManager?.undoActionName == "Insert Files")
        tv.undoManager?.undo()
        try? await Task.sleep(for: .seconds(0.3))
        #expect(box.text == "Before\nAfter")
    }
}
#endif
