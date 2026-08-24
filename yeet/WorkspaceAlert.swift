//
//  WorkspaceAlert.swift
//  kero
//

import AppKit

/// AppKit confirmation sheets used by close, trash, and git. Presented on
/// `window` when possible so they do not block every window in a
/// multi-window quit.
enum WorkspaceAlert {
    enum UnsavedDecision {
        case save
        case discard
        case cancel
    }

    @MainActor
    static func present(
        _ alert: NSAlert,
        on window: NSWindow?
    ) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }

    @MainActor
    static func unsavedChanges(for title: String, on window: NSWindow?) async -> UnsavedDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Do you want to save the changes you made to \(title)?",
            comment: "Unsaved file or diff confirmation. The placeholder is a file name."
        )
        alert.informativeText = String(localized: "Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        let dontSave = alert.addButton(withTitle: String(localized: "Don’t Save"))
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"

        switch await present(alert, on: window) {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    @MainActor
    static func confirm(
        message: String,
        informative: String,
        confirmTitle: String,
        style: NSAlert.Style = .warning,
        on window: NSWindow?
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: confirmTitle)
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        return await present(alert, on: window) == .alertFirstButtonReturn
    }
}
