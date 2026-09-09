//
//  ChatTimelineItem.swift
//  kero
//

import Foundation

enum ChatApprovalDecision: String, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

struct ChatTurnFile: Equatable, Sendable {
    var path: String
    var added: Int
    var removed: Int
}

/// View-model rows for the chat timeline. Hunks and full logs stay out;
/// cards hold a one-line summary plus an optional short preview.
enum ChatTimelineItem: Identifiable, Equatable, Sendable {
    case user(id: String, text: String)
    case assistant(id: String, text: String)
    case reasoning(id: String, summary: String, expanded: Bool)
    case tool(id: String, path: String, added: Int, removed: Int, status: String)
    case command(
        id: String,
        command: String,
        exitCode: Int?,
        durationMs: Int?,
        outputPreview: String,
        expanded: Bool
    )
    case turnFiles(id: String, files: [ChatTurnFile])
    case approval(
        id: String,
        requestID: JSONRPCID,
        kind: Kind,
        title: String,
        detail: String
    )
    case error(id: String, message: String)
    case turnFinished(id: String)

    enum Kind: Equatable, Sendable {
        case command
        case fileChange
    }

    var id: String {
        switch self {
        case .user(let id, _),
             .assistant(let id, _),
             .reasoning(let id, _, _),
             .tool(let id, _, _, _, _),
             .command(let id, _, _, _, _, _),
             .turnFiles(let id, _),
             .approval(let id, _, _, _, _),
             .error(let id, _),
             .turnFinished(let id):
            return id
        }
    }
}

enum ChatTimelinePreview {
    static let commandLineLimit = 20

    static func truncateOutput(_ text: String, lineLimit: Int = commandLineLimit) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= lineLimit {
            return text
        }
        return lines.prefix(lineLimit).joined(separator: "\n")
    }

    /// Counts `+` / `-` body lines in a unified diff, ignoring headers.
    static func diffLineCounts(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                continue
            }
            if line.hasPrefix("+") {
                added += 1
            } else if line.hasPrefix("-") {
                removed += 1
            }
        }
        return (added, removed)
    }
}
