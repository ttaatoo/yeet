//
//  ClipboardAccessPolicy.swift
//  kero
//

import Foundation

/// Whether a terminal program may use OSC 52 to read or write the macOS
/// clipboard. Raw values match Ghostty's `clipboard-read` / `clipboard-write`.
enum ClipboardAccessPolicy: String, CaseIterable, Identifiable, Sendable {
    case ask
    case allow
    case deny

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: String(localized: "Ask")
        case .allow: String(localized: "Allow")
        case .deny: String(localized: "Deny")
        }
    }

    /// Resolves the request when no sheet is needed. Returns `true` when the
    /// caller must present a confirmation.
    @MainActor
    func needsConfirmation(for request: TerminalClipboardRequest) -> Bool {
        switch self {
        case .ask:
            return true
        case .allow:
            request.approve()
            return false
        case .deny:
            request.deny()
            return false
        }
    }
}
