//
//  ACPEventMapper.swift
//  kero
//

import Foundation

/// Projects ACP `session/update` and `session/request_permission` into chat
/// timeline items. Used by Grok (`grok agent stdio`).
struct ACPEventMapper {
    private var assistantText: [String: String] = [:]
    private var thinkingText: [String: String] = [:]
    private var files: [ChatTurnFile] = []

    mutating func applyNotification(
        method: String,
        params: KeroJSONValue?
    ) -> [ChatTimelineItem] {
        guard method == "session/update" else { return [] }
        let object = params?.objectValue ?? [:]
        let update = object["update"]?.objectValue ?? object
        let type = update["sessionUpdate"]?.stringValue ?? ""
        switch type {
        case "agent_message_chunk":
            let id = update["messageId"]?.stringValue ?? "assistant"
            let delta = textContent(update["content"])
            assistantText[id, default: ""].append(delta)
            return [.assistant(id: id, text: assistantText[id] ?? delta)]
        case "agent_thought_chunk":
            let id = update["messageId"]?.stringValue ?? "thinking"
            let delta = textContent(update["content"])
            thinkingText[id, default: ""].append(delta)
            return [.reasoning(id: id, summary: thinkingText[id] ?? delta, expanded: false)]
        case "tool_call", "tool_call_update":
            return mapTool(update)
        default:
            return []
        }
    }

    func applyPermissionRequest(
        id: JSONRPCID,
        params: KeroJSONValue?
    ) -> ChatTimelineItem {
        let object = params?.objectValue ?? [:]
        let tool = object["toolCall"]?.objectValue ?? [:]
        let title = tool["title"]?.stringValue
            ?? object["title"]?.stringValue
            ?? String(localized: "Allow this action?")
        let command = tool["rawInput"]?.objectValue?["command"]?.stringValue
        let path = tool["locations"]?.arrayValue?.first?.objectValue?["path"]?.stringValue
            ?? diffPath(tool["content"])
        let kind: ChatTimelineItem.Kind = {
            let toolKind = tool["kind"]?.stringValue ?? ""
            if toolKind == "execute" { return .command }
            return .fileChange
        }()
        let detail = command ?? path ?? title
        return .approval(
            id: "approval-\(idKey(id))",
            requestID: id,
            kind: kind,
            title: title,
            detail: detail
        )
    }

    static func permissionResult(
        _ decision: ChatApprovalDecision,
        options: [KeroJSONValue]
    ) -> KeroJSONValue {
        if decision == .cancel {
            return .object(["outcome": .object(["outcome": .string("cancelled")])])
        }
        let wanted: String = {
            switch decision {
            case .accept: return "allow_once"
            case .acceptForSession: return "allow_always"
            case .decline: return "reject_once"
            case .cancel: return "reject_once"
            }
        }()
        let fallback = decision == .decline ? "reject_once" : "allow_once"
        let optionId = optionID(kind: wanted, in: options)
            ?? optionID(kind: fallback, in: options)
            ?? options.first?.objectValue?["optionId"]?.stringValue
            ?? "allow-once"
        return .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(optionId),
            ]),
        ])
    }

    private mutating func mapTool(
        _ update: [String: KeroJSONValue]
    ) -> [ChatTimelineItem] {
        let id = update["toolCallId"]?.stringValue ?? UUID().uuidString
        let kind = update["kind"]?.stringValue ?? ""
        let status = update["status"]?.stringValue ?? "pending"
        let title = update["title"]?.stringValue ?? ""
        if kind == "execute" {
            let command = update["rawInput"]?.objectValue?["command"]?.stringValue
                ?? title
            let output = terminalPreview(update["content"])
            return [
                .command(
                    id: id,
                    command: command,
                    exitCode: nil,
                    durationMs: nil,
                    outputPreview: ChatTimelinePreview.truncateOutput(output),
                    expanded: false
                ),
            ]
        }
        let path = update["locations"]?.arrayValue?.first?.objectValue?["path"]?.stringValue
            ?? diffPath(update["content"])
            ?? title
        let counts = diffCounts(update["content"])
        if !path.isEmpty {
            let file = ChatTurnFile(path: path, added: counts.added, removed: counts.removed)
            if let index = files.firstIndex(where: { $0.path == path }) {
                files[index] = file
            } else {
                files.append(file)
            }
        }
        var items: [ChatTimelineItem] = [
            .tool(
                id: id,
                path: path,
                added: counts.added,
                removed: counts.removed,
                status: status
            ),
        ]
        if !files.isEmpty {
            items.append(.turnFiles(id: "files-turn", files: files))
        }
        return items
    }

    private func textContent(_ value: KeroJSONValue?) -> String {
        if let text = value?.stringValue { return text }
        if let object = value?.objectValue {
            return object["text"]?.stringValue ?? ""
        }
        return ""
    }

    private func diffPath(_ content: KeroJSONValue?) -> String? {
        guard let blocks = content?.arrayValue else { return nil }
        for block in blocks {
            if block.objectValue?["type"]?.stringValue == "diff" {
                return block.objectValue?["path"]?.stringValue
            }
        }
        return nil
    }

    private func diffCounts(_ content: KeroJSONValue?) -> (added: Int, removed: Int) {
        guard let blocks = content?.arrayValue else { return (0, 0) }
        var added = 0
        var removed = 0
        for block in blocks {
            guard block.objectValue?["type"]?.stringValue == "diff" else { continue }
            let old = block.objectValue?["oldText"]?.stringValue ?? ""
            let new = block.objectValue?["newText"]?.stringValue ?? ""
            let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).count
            let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).count
            if newLines > oldLines { added += newLines - oldLines }
            if oldLines > newLines { removed += oldLines - newLines }
            if newLines == oldLines, new != old {
                added += 1
                removed += 1
            }
        }
        return (added, removed)
    }

    private func terminalPreview(_ content: KeroJSONValue?) -> String {
        guard let blocks = content?.arrayValue else {
            return content?.stringValue ?? ""
        }
        let texts = blocks.compactMap { block -> String? in
            let object = block.objectValue ?? [:]
            if object["type"]?.stringValue == "content" {
                return object["content"]?.objectValue?["text"]?.stringValue
            }
            return object["text"]?.stringValue
        }
        return texts.joined(separator: "\n")
    }

    private static func optionID(kind: String, in options: [KeroJSONValue]) -> String? {
        for option in options {
            let object = option.objectValue ?? [:]
            if object["kind"]?.stringValue == kind {
                return object["optionId"]?.stringValue
            }
        }
        return nil
    }

    private func idKey(_ id: JSONRPCID) -> String {
        switch id {
        case .number(let value): return String(value)
        case .string(let value): return value
        }
    }
}
