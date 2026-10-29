//
//  EditorUIKitTests.swift
//  MarkdownEngineTests
//
//  End-to-end UIKit editor tests (table grid, file drops): the real SwiftUI wrapper in a
//  window, driven through the grid like a user would, asserting on the
//  markdown binding. Hosted by the demo app so UIKit has a window scene to
//  lay out and render in (package tests on iOS run without one).
//

#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import MarkdownEngineCore

@MainActor
@Suite("UIKit editor", .serialized)
struct EditorUIKitTests {

    final class Box { var text: String; init(_ t: String) { text = t } }

    struct Harness {
        let window: UIWindow
        let box: Box

        static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
            if let match = view as? T { return match }
            for sub in view.subviews { if let match = find(type, in: sub) { return match } }
            return nil
        }

        var textView: MarkdownUITextView? { Self.find(MarkdownUITextView.self, in: window) }
        var grid: TableGridUIView? { textView.flatMap { Self.find(TableGridUIView.self, in: $0) } }
        var field: TableCellTextField? { grid.flatMap { Self.find(TableCellTextField.self, in: $0) } }

        func spin(_ seconds: Double = 0.3) async {
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    private func makeHarness(_ text: String, onDropFiles: FileDropHandler? = nil) async -> Harness {
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIHostingController(rootView: NativeTextViewWrapper(text: binding, fontSize: 15, onDropFiles: onDropFiles))
        window.makeKeyAndVisible()
        let h = Harness(window: window, box: box)
        await h.spin(0.6)
        return h
    }

    private func snapshot(_ h: Harness, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MDE_SNAPSHOT_DIR"] else { return }
        let image = UIGraphicsImageRenderer(bounds: h.window.bounds).image { _ in
            h.window.drawHierarchy(in: h.window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private let doc = "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nOutro"

    @Test func everyTableGetsAGrid() async throws {
        let h = await makeHarness(doc)
        let grid = try #require(h.grid)
        #expect(grid.info.table.header == ["a", "b"])
        snapshot(h, "ios-grid-initial")
    }

    @Test func editingACellAndReturnRewritesTheMarkdown() async throws {
        let h = await makeHarness(doc)
        try #require(h.grid).beginEditing(row: 0, column: 1)
        await h.spin()
        let field = try #require(h.field)
        #expect(field.text == "b")
        field.text = "B *x*"
        field.sendActions(for: .editingChanged)   // as typing would
        #expect(field.frame.width >= ("B *x*" as NSString).size(withAttributes: [.font: field.font as Any]).width)
        snapshot(h, "ios-grid-editing")
        _ = field.delegate?.textFieldShouldReturn?(field)
        await h.spin()
        #expect(h.box.text == "Intro\n\n| a   | B *x* |\n| --- | ----- |\n| 1   | 2     |\n\nOutro")
        #expect(h.grid?.editingCell?.row == 1)
        #expect(h.grid?.editingCell?.column == 1)
        snapshot(h, "ios-grid-after-return")
    }

    @Test func returnInTheLastRowAddsARow() async throws {
        let h = await makeHarness(doc)
        try #require(h.grid).beginEditing(row: 1, column: 0)
        await h.spin()
        let field = try #require(h.field)
        _ = field.delegate?.textFieldShouldReturn?(field)
        await h.spin()
        let table = try #require(MarkdownTable(source: h.box.text.components(separatedBy: "\n\n")[1]))
        #expect(table.rows == [["1", "2"], ["", ""]])
        #expect(h.grid?.editingCell?.row == 2)
    }

    @Test func caretIntoTableFocusesTheGrid() async throws {
        let h = await makeHarness(doc)
        let tv = try #require(h.textView)
        tv.becomeFirstResponder()
        tv.selectedRange = NSRange(location: 0, length: 0)
        await h.spin()
        tv.selectedRange = NSRange(location: (doc as NSString).range(of: "| a").location, length: 0)
        await h.spin()
        #expect(h.grid?.editingCell?.row == 0)
        #expect(h.field != nil)
    }

    @Test func cellEditIsOneUndoStep() async throws {
        let h = await makeHarness(doc)
        try #require(h.grid).beginEditing(row: 1, column: 0)
        await h.spin()
        let field = try #require(h.field)
        field.text = "9"
        _ = field.delegate?.textFieldShouldReturn?(field)
        await h.spin()
        #expect(h.box.text.contains("| 9   | 2   |"))
        let tv = try #require(h.textView)
        tv.undoManager?.undo()
        await h.spin()
        #expect(h.box.text == doc, "\(h.box.text.debugDescription)")
        tv.undoManager?.redo()
        await h.spin()
        #expect(h.box.text.contains("| 9   | 2   |"))
    }

    @Test func fileDropInsertsHandlerMarkdownAsOneUndoStep() async throws {
        let h = await makeHarness("Before\nAfter") { files in
            files.map { $0.markdownLink(to: "_attachments/\($0.name)") }.joined(separator: "\n")
        }
        let tv = try #require(h.textView)
        await tv.insertDroppedFiles([DroppedFile(url: URL(fileURLWithPath: "/tmp/cat.png"))], at: 7)
        await h.spin()
        #expect(h.box.text == "Before\n![](_attachments/cat.png)After")
        tv.undoManager?.undo()
        await h.spin()
        #expect(h.box.text == "Before\nAfter")
    }
}
#endif
