//
//  MarkdownEditorController.swift
//  MarkdownEngine
//
//  A handle on one editor, for commands that come from outside it (a
//  "Link to Note" picker, toolbar buttons). Pass it to
//  `NativeTextViewWrapper(controller:)`; unlike the notification bus it
//  addresses exactly this editor, so several windows don't interfere.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Observation

@MainActor
@Observable
public final class MarkdownEditorController {
    #if os(macOS)
    @ObservationIgnored weak var textView: NativeTextView? {
        didSet { if textView !== oldValue { observeEditing() } }
    }
    #else
    @ObservationIgnored weak var textView: MarkdownUITextView? {
        didSet {
            textView?.editorController = self
            if textView !== oldValue { observeEditing() }
        }
    }
    #endif

    /// True while the editor has keyboard focus (iOS: while editing), e.g.
    /// to show a formatting bar above the keyboard.
    public private(set) var isEditing = false
    /// The editor or one of its table cells has the keyboard.
    public var isEditingAnything: Bool { isEditing || tableCell != nil }
    /// The block style of the caret's line, refreshed as the selection moves.
    public private(set) var currentBlockStyle: MarkdownFormatting.BlockStyle = .body

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The table cell being edited in its own field (iOS grid), if any.
    public struct TableCell: Equatable, Sendable {
        /// 0 is the header row; data rows count from 1, as in formulas.
        public let row: Int
        public let column: Int
        /// The cell's formula address ("B2"); nil for the header row.
        public var address: String? {
            guard row > 0 else { return nil }
            return MarkdownEditorController.columnName(column) + String(row)
        }
    }

    /// Set while a table cell is edited; formatting and formula buttons act on it.
    public private(set) var tableCell: TableCell?
    #if os(iOS)
    @ObservationIgnored private weak var cellField: UITextField?

    func tableCellDidBeginEditing(_ field: UITextField, row: Int, column: Int) {
        cellField = field
        tableCell = TableCell(row: row, column: column)
    }

    func tableCellDidEndEditing(_ field: UITextField) {
        guard cellField === field else { return }
        cellField = nil
        tableCell = nil
    }
    #endif

    /// A, B, … Z, AA, AB …
    nonisolated static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    // MARK: Table cell editing

    /// Inserts `text` at the cell's caret (e.g. `:` or a cell reference).
    public func insertInTableCell(_ text: String) {
        #if os(iOS)
        guard let field = cellField else { return }
        field.insertText(text)
        #endif
    }

    /// Starts or extends a formula with `FUNCTION()`, caret between the
    /// parentheses. An empty cell becomes `=FUNCTION()`; other text gets
    /// an `=` in front.
    public func insertFunctionInTableCell(_ name: String) {
        #if os(iOS)
        guard let field = cellField else { return }
        var text = field.text ?? ""
        if !text.hasPrefix("=") {
            text = "=" + text
            field.text = text
            if let end = field.position(from: field.endOfDocument, offset: 0) {
                field.selectedTextRange = field.textRange(from: end, to: end)
            }
        }
        field.insertText("\(name)()")
        if let caret = field.selectedTextRange?.start, let inside = field.position(from: caret, offset: -1) {
            field.selectedTextRange = field.textRange(from: inside, to: inside)
        }
        field.sendActions(for: .editingChanged)
        #endif
    }

    public init() {}

    private func observeEditing() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let textView else { return }
        #if os(macOS)
        let names: [(Notification.Name, Bool?)] = [
            (NSText.didBeginEditingNotification, true), (NSText.didEndEditingNotification, false),
            (NSTextView.didChangeSelectionNotification, nil),
        ]
        #else
        let names: [(Notification.Name, Bool?)] = [
            (UITextView.textDidBeginEditingNotification, true), (UITextView.textDidEndEditingNotification, false),
            (UITextView.textDidChangeNotification, nil),
        ]
        #endif
        for (name, editing) in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: textView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let editing { self?.isEditing = editing }
                    self?.refreshBlockStyle()
                }
            })
        }
    }

    /// Re-reads the caret's block style (iOS posts no selection notification;
    /// the coordinator calls this when the selection changes).
    func refreshBlockStyle() {
        guard let textView, let range = selectedRange else { return }
        let style = MarkdownFormatting.blockStyle(at: range.location, in: textView.string)
        if style != currentBlockStyle { currentBlockStyle = style }
    }

    // MARK: Formatting

    /// Bold, italic, strikethrough or inline code around the selection (toggles).
    public func toggle(_ style: MarkdownFormatting.InlineStyle) {
        #if os(iOS)
        if let field = cellField, let range = field.selectedTextRange {
            let text = field.text ?? ""
            let start = field.offset(from: field.beginningOfDocument, to: range.start)
            let end = field.offset(from: field.beginningOfDocument, to: range.end)
            let edit = MarkdownFormatting.toggle(style, in: text, selection: NSRange(location: start, length: end - start))
            field.text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            if let a = field.position(from: field.beginningOfDocument, offset: edit.selection.location),
               let b = field.position(from: a, offset: edit.selection.length) {
                field.selectedTextRange = field.textRange(from: a, to: b)
            }
            field.sendActions(for: .editingChanged)
            return
        }
        #endif
        perform("Format") { MarkdownFormatting.toggle(style, in: $0, selection: $1) }
    }

    /// Makes the selected lines body text, a heading, a list or a quote
    /// (applying the style they already all have turns them back into body text).
    public func setBlockStyle(_ style: MarkdownFormatting.BlockStyle) {
        perform("Format") { MarkdownFormatting.setBlock(style, in: $0, selection: $1) }
    }

    public func indent() { perform("Indent") { MarkdownFormatting.indent(true, in: $0, selection: $1) } }
    public func outdent() { perform("Outdent") { MarkdownFormatting.indent(false, in: $0, selection: $1) } }

    /// Inserts an empty table and puts the caret in its first cell.
    public func insertTable(columns: Int = 2, rows: Int = 2) {
        perform("Insert Table") { MarkdownFormatting.insertTable(columns: columns, rows: rows, in: $0, selection: $1) }
    }

    private func perform(_ actionName: String, _ makeEdit: (String, NSRange) -> MarkdownFormattingEdit) {
        guard let textView, let selection = selectedRange else { return }
        let edit = makeEdit(textView.string, selection)
        textView.insertMarkdown(edit.replacement, replacing: edit.range, actionName: actionName)
        let length = (textView.string as NSString).length
        let start = min(edit.selection.location, length)
        textView.setSelectedRange(NSRange(location: start, length: min(edit.selection.length, length - start)))
        refreshBlockStyle()
    }

    /// Shows the find bar (with replace when `replacing`), seeded with the selection.
    public func showFind(replacing: Bool = false) {
        guard let textView else { return }
        #if os(macOS)
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = Int((replacing ? NSTextFinder.Action.showReplaceInterface : NSTextFinder.Action.showFindInterface).rawValue)
        textView.performTextFinderAction(item)
        #else
        textView.findInteraction?.presentFindNavigator(showingReplace: replacing)
        #endif
    }

    /// Hides the keyboard (iOS) / gives up focus.
    public func endEditing() {
        #if os(macOS)
        textView?.window?.makeFirstResponder(nil)
        #else
        cellField?.resignFirstResponder()
        textView?.resignFirstResponder()
        #endif
    }

    /// True once the editor's view exists.
    public var isAttached: Bool { textView != nil }

    /// The current selection (UTF-16 range in the markdown source).
    public var selectedRange: NSRange? {
        #if os(macOS)
        textView?.selectedRange()
        #else
        textView?.selectedRange
        #endif
    }

    /// Replaces the selection with `text` (raw markdown) as one undoable
    /// edit and puts the caret after it.
    public func insertText(_ text: String, actionName: String = "Insert") {
        guard let textView else { return }
        #if os(macOS)
        let selection = textView.selectedRange()
        #else
        let selection = textView.selectedRange
        #endif
        textView.insertMarkdown(text, replacing: selection, actionName: actionName)
    }

    /// Selects `range` (UTF-16, clamped) and scrolls it into view, e.g. to
    /// jump to a heading from an outline.
    public func reveal(_ range: NSRange) {
        guard let textView else { return }
        let length = (textView.string as NSString).length
        let start = min(max(range.location, 0), length)
        let clamped = NSRange(location: start, length: min(range.length, length - start))
        textView.setSelectedRange(clamped)
        textView.scrollRangeToVisible(clamped)
        focus()
    }

    // MARK: Image and link attributes

    /// The image, link or bare URL at the selection's start, e.g. to enable
    /// and check "Image Size" / "Show as Preview Card" menu items.
    public var attributeTarget: MarkdownAttributeTarget? {
        guard let textView else { return nil }
        #if os(macOS)
        let location = textView.selectedRange().location
        #else
        let location = textView.selectedRange.location
        #endif
        return MarkdownAttributeEditing.target(at: location, in: textView.string)
    }

    /// Sets the size of the image at the selection (`nil` = original size).
    /// Returns false when there's no image there or nothing changed.
    @discardableResult
    public func setImageSize(_ size: MarkdownAttributes.Size?) -> Bool {
        apply(.size(size), kinds: [.image])
    }

    /// Sets the size of the preview card at the selection (`.icon` shows the
    /// link with its site icon instead).
    @discardableResult
    public func setLinkCardSize(_ size: MarkdownAttributes.Size?) -> Bool {
        guard attributeTarget?.isPreview == true else { return false }
        return apply(.size(size), kinds: [.link])
    }

    /// Aligns the image or preview card at the selection (`nil` = left).
    @discardableResult
    public func setAlignment(_ alignment: MarkdownAttributes.Alignment?) -> Bool {
        apply(.align(alignment), kinds: [.image, .link])
    }

    /// Shows the link (or bare URL) at the selection as a preview card, or
    /// back as a plain link.
    @discardableResult
    public func setLinkPreview(_ on: Bool) -> Bool {
        apply(.preview(on), kinds: [.link, .bareURL])
    }

    private func apply(_ action: MarkerAction, kinds: Set<MarkdownAttributeTarget.Kind>) -> Bool {
        guard let textView else { return false }
        #if os(macOS)
        let location = textView.selectedRange().location
        #else
        let location = textView.selectedRange.location
        #endif
        return textView.applyMarkerAction(action, at: location, kinds: kinds)
    }

    /// Makes the editor first responder.
    public func focus() {
        #if os(macOS)
        textView?.window?.makeFirstResponder(textView)
        #else
        textView?.becomeFirstResponder()
        #endif
    }
}
