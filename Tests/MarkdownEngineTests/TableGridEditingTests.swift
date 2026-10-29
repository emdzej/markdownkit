//
//  TableGridEditingTests.swift
//  MarkdownEngineTests
//
//  End-to-end table grid editing on macOS: the real SwiftUI wrapper in a
//  window, driven through the grid the way a user would (focus a cell,
//  type, press Tab / Return / Up), asserting on the markdown binding.
//

#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngineCore

@MainActor
@Suite("Table grid editing", .serialized)
struct TableGridEditingTests {

    final class Box { var text: String; init(_ t: String) { text = t } }

    /// The editor hosted in an off-screen window; keep it alive for the test.
    struct Harness {
        let window: NSWindow
        let box: Box

        var textView: NativeTextView? { window.contentView.flatMap { Self.find(NativeTextView.self, in: $0) } }

        static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for sub in view.subviews { if let match = find(type, in: sub) { return match } }
            return nil
        }

        var grid: TableGridView? { textView.flatMap { Self.find(TableGridView.self, in: $0) } }
        var field: TableCellField? { grid.flatMap { Self.find(TableCellField.self, in: $0) } }

        /// Lets queued main-queue work (restyles, overlay updates) run. The
        /// test itself is a main-actor job, so it has to suspend for that;
        /// a nested `RunLoop.run` can't drain the main queue.
        func spin(_ seconds: Double = 0.25) async {
            try? await Task.sleep(for: .seconds(seconds))
        }

        /// Types into the focused cell and sends a key command (`insertTab:` …).
        func type(_ text: String, then command: Selector?) async {
            guard let field, let editor = field.currentEditor() as? NSTextView else {
                Issue.record("no cell is being edited")
                return
            }
            editor.insertText(text, replacementRange: editor.selectedRange())
            if let command { editor.doCommand(by: command) }
            await spin()
        }
    }

    private func makeHarness(_ text: String) async -> Harness {
        _ = NSApplication.shared
        let box = Box(text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let root = NativeTextViewWrapper(text: binding, fontName: "Helvetica", fontSize: 14)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        let harness = Harness(window: window, box: box)
        await harness.spin(0.5)
        return harness
    }

    /// Writes the window's content to `path` for visual inspection when
    /// `MDE_SNAPSHOT_DIR` is set.
    private func snapshot(_ h: Harness, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MDE_SNAPSHOT_DIR"],
              let view = h.window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private let doc = "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nOutro"

    @Test func everyTableGetsAGrid() async throws {
        let h = await makeHarness(doc)
        defer { h.window.close() }
        let grid = try #require(h.grid)
        #expect(grid.info.table.header == ["a", "b"])
        snapshot(h, "grid-initial")
    }

    @Test func editingACellRewritesTheMarkdown() async throws {
        let h = await makeHarness(doc)
        defer { h.window.close() }
        let grid = try #require(h.grid)
        grid.beginEditing(row: 1, column: 0)
        await h.spin()
        #expect(h.field?.stringValue == "1")
        snapshot(h, "grid-editing")

        await h.type("0 **bold**", then: #selector(NSResponder.insertTab(_:)))
        #expect(h.box.text == "Intro\n\n| a           | b   |\n| ----------- | --- |\n| 10 **bold** | 2   |\n\nOutro")
        // Tab moved on to the next cell of the re-rendered table.
        #expect(h.grid?.editingCell?.row == 1)
        #expect(h.grid?.editingCell?.column == 1)
        snapshot(h, "grid-after-tab")
    }

    @Test func tabPastLastCellAddsARow() async throws {
        let h = await makeHarness(doc)
        defer { h.window.close() }
        try #require(h.grid).beginEditing(row: 1, column: 1)
        await h.spin()
        await h.type("", then: #selector(NSResponder.insertTab(_:)))
        let table = try #require(MarkdownTable(source: h.box.text.components(separatedBy: "\n\n")[1]))
        #expect(table.rows == [["1", "2"], ["", ""]])
        #expect(h.grid?.editingCell?.row == 2)
    }

    @Test func escapeDiscardsTheCellEdit() async throws {
        let h = await makeHarness(doc)
        defer { h.window.close() }
        try #require(h.grid).beginEditing(row: 1, column: 0)
        await h.spin()
        await h.type("changed", then: #selector(NSResponder.cancelOperation(_:)))
        #expect(h.box.text == doc)
        #expect(h.window.firstResponder === h.textView)
    }

    @Test func editIsOneUndoStep() async throws {
        let h = await makeHarness(doc)
        defer { h.window.close() }
        try #require(h.grid).beginEditing(row: 0, column: 1)
        await h.spin()
        await h.type("B", then: #selector(NSResponder.insertNewline(_:)))
        #expect(h.box.text.contains("| a   | bB  |"))
        h.window.makeFirstResponder(h.textView)
        #expect(h.textView?.undoManager?.undoActionName == "Edit Table")
        h.textView?.undoManager?.undo()
        await h.spin()
        #expect(h.box.text == doc, "\(h.box.text.debugDescription)")
    }

    @Test func arrowKeyIntoTableFocusesTheGrid() async throws {
        let h = await makeHarness(doc)
        defer { h.window.close() }
        h.window.makeFirstResponder(h.textView)
        h.textView?.setSelectedRange(NSRange(location: 0, length: 0))
        await h.spin()
        // Move the caret onto the table's first line, as Down-arrow would.
        h.textView?.setSelectedRange(NSRange(location: (doc as NSString).range(of: "| a").location, length: 0))
        await h.spin()
        #expect(h.grid?.editingCell?.row == 0)
        #expect(h.field != nil)
    }

    /// Runs the grid's context-menu item `title` for `cell`.
    private func runMenu(_ h: Harness, _ title: String, row: Int, column: Int) throws {
        let grid = try #require(h.grid)
        let cell = grid.info.layout.cellRect(row: row, column: column)
        let point = grid.convert(CGPoint(x: cell.midX, y: cell.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let item = try #require(grid.menu(for: event)?.items.first { $0.title == title })
        #expect(item.isEnabled)
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }

    @Test func contextMenuInsertsAColumnAndSetsAlignment() async throws {
        let h = await makeHarness(doc)
        defer { h.window.close() }
        try runMenu(h, "Insert Column Right", row: 1, column: 0)
        await h.spin()
        try runMenu(h, "Align Right", row: 0, column: 2)
        await h.spin()
        let table = try #require(MarkdownTable(source: h.box.text.components(separatedBy: "\n\n")[1]))
        #expect(table.header == ["a", "", "b"])
        #expect(table.alignments == [.none, .none, .right])
        #expect(table.rows == [["1", "", "2"]])
    }

    @Test func editAsMarkdownRevealsSourceUntilTheCaretLeaves() async throws {
        let h = await makeHarness(doc)
        defer { h.window.close() }
        try runMenu(h, "Edit as Markdown", row: 1, column: 0)
        await h.spin()
        let tv = try #require(h.textView)
        let start = (doc as NSString).range(of: "| a").location
        #expect(tv.coordinator?.revealedTableLocation == start)
        #expect(h.grid == nil)   // raw source, no overlay
        #expect(h.window.firstResponder === tv)
        snapshot(h, "edit-as-markdown")

        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await h.spin()
        #expect(tv.coordinator?.revealedTableLocation == nil)
        #expect(h.grid != nil)
    }
}
#endif
