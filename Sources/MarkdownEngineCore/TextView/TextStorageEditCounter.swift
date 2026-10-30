//
//  TextStorageEditCounter.swift
//  MarkdownEngine
//
//  Counts character edits of one text storage so a parse cache can answer
//  "has the text changed since I parsed it?" in O(1) instead of comparing
//  the whole document on every keystroke and caret move.
//
//  Adapted from swift-markdown-engine #96, which bumps a generation counter
//  by hand at each delegate entry point. Observing the storage itself also
//  catches edits that bypass the delegate (direct storage mutations from
//  tables, checklists, find & replace, IME composition), so a same-length
//  edit can never be served a stale parse.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class TextStorageEditCounter: NSObject {
    /// Bumped on every processed edit that changed characters, and whenever
    /// the tracked storage changes. Attribute-only edits (restyles) leave it.
    private(set) var generation: UInt64 = 0
    private weak var storage: NSTextStorage?

    /// Starts tracking `newStorage` (no-op if already tracked).
    func track(_ newStorage: NSTextStorage?) {
        guard newStorage !== storage else { return }
        let center = NotificationCenter.default
        if let storage {
            center.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        storage = newStorage
        generation &+= 1
        if let newStorage {
            center.addObserver(self, selector: #selector(didProcessEditing(_:)),
                               name: NSTextStorage.didProcessEditingNotification, object: newStorage)
        }
    }

    /// True when `candidate` is the storage whose edits this counter sees.
    func tracks(_ candidate: NSTextStorage?) -> Bool {
        candidate != nil && candidate === storage
    }

    @objc private func didProcessEditing(_ notification: Notification) {
        guard let edited = notification.object as? NSTextStorage,
              edited.editedMask.contains(.editedCharacters) else { return }
        generation &+= 1
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
