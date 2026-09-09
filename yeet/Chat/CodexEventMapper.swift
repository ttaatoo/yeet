//
//  CodexEventMapper.swift
//  kero
//

import Foundation

/// Projects Codex app-server JSONL notifications and inbound requests into
/// chat timeline items. Unknown methods are ignored so a newer CLI does not
/// break the pane.
struct CodexEventMapper {
    private var assistantText: [String: String] = [:]
    private var filesByTurn: [String: [ChatTurnFile]] = [:]
    private var droppedThreadIDs: Set<String> = []

    mutating func push(lines: [String]) throws -> [ChatTimelineItem] {
        var items: [ChatTimelineItem] = []
        for line in lines {
            items.append(contentsOf: try push(line: line))
        }
        return items
    }

    mutating func push(line: String) throws -> [ChatTimelineItem] {
        let message = try JSONRPCCodec.decodeLine(line)
        switch message {
        case .notification(let method, let params):
            return applyNotification(method: method, params: params)
        case .request(let id, let method, let params):
            return applyRequest(id: id, method: method, params: params)
        case .response, .error:
            return []
        }
    }

    private mutating func applyNotification(
        method: String,
        params: KeroJSONValue?
    ) -> [ChatTimelineItem] {
        let object = params?.objectValue ?? [:]
        if shouldDrop(object) { return [] }
        switch method {
        case "item/started", "item/completed":
            return upsertItem(object["item"]?.objectValue, completed: method == "item/completed")
        case "item/agentMessage/delta":
            return appendAssistantDelta(object)
        case "item/reasoning/summaryTextDelta",
             "item/reasoning/textDelta",
             "item/reasoning/summaryPartAdded":
            return upsertReasoning(object)
        case "item/commandExecution/outputDelta":
            return []
        case "turn/diff/updated":
            return replaceTurnFiles(object)
        case "error":
            let message = object["error"]?.objectValue?["message"]?.stringValue
                ?? object["message"]?.stringValue
                ?? String(localized: "The Codex turn failed.")
            let id = object["turnId"]?.stringValue ?? "error"
            return [.error(id: id, message: message)]
        case "turn/completed":
            let turn = object["turn"]?.objectValue
            let id = turn?["id"]?.stringValue ?? object["turnId"]?.stringValue ?? "turn"
            if let status = turn?["status"]?.stringValue, status == "failed" {
                let message = turn?["error"]?.objectValue?["message"]?.stringValue
                    ?? String(localized: "The Codex turn failed.")
                return [.error(id: id, message: message)]
            }
            return [.turnFinished(id: id)]
        default:
            return []
        }
    }

    private func applyRequest(
        id: JSONRPCID,
        method: String,
        params: KeroJSONValue?
    ) -> [ChatTimelineItem] {
        let object = params?.objectValue ?? [:]
        if shouldDrop(object) { return [] }
        switch method {
        case "item/commandExecution/requestApproval":
            let command = object["command"]?.stringValue ?? ""
            return [
                .approval(
                    id: "approval-\(idKey(id))",
                    requestID: id,
                    kind: .command,
                    title: String(localized: "Allow command?"),
                    detail: command
                ),
            ]
        case "item/fileChange/requestApproval":
            let path = object["grantRoot"]?.stringValue
                ?? object["reason"]?.stringValue
                ?? String(localized: "File change")
            return [
                .approval(
                    id: "approval-\(idKey(id))",
                    requestID: id,
                    kind: .fileChange,
                    title: String(localized: "Allow file change?"),
                    detail: path
                ),
            ]
        default:
            return []
        }
    }

    private mutating func upsertItem(
        _ item: [String: KeroJSONValue]?,
        completed: Bool
    ) -> [ChatTimelineItem] {
        guard let item else { return [] }
        let type = item["type"]?.stringValue ?? ""
        let id = item["id"]?.stringValue ?? UUID().uuidString
        switch type {
        case "userMessage":
            let text = textContent(item["content"]) ?? item["text"]?.stringValue ?? ""
            return [.user(id: id, text: text)]
        case "agentMessage":
            let text = item["text"]?.stringValue ?? assistantText[id] ?? ""
            assistantText[id] = text
            return [.assistant(id: id, text: text)]
        case "reasoning":
            let summary = reasoningSummary(item)
            return [.reasoning(id: id, summary: summary, expanded: false)]
        case "fileChange":
            let files = fileChanges(item["changes"])
            let first = files.first
            return [
                .tool(
                    id: id,
                    path: first?.path ?? "",
                    added: files.reduce(0) { $0 + $1.added },
                    removed: files.reduce(0) { $0 + $1.removed },
                    status: item["status"]?.stringValue ?? (completed ? "completed" : "inProgress")
                ),
            ]
        case "commandExecution":
            let output = item["aggregatedOutput"]?.stringValue ?? ""
            return [
                .command(
                    id: id,
                    command: item["command"]?.stringValue ?? "",
                    exitCode: item["exitCode"]?.intValue,
                    durationMs: item["durationMs"]?.intValue,
                    outputPreview: ChatTimelinePreview.truncateOutput(output),
                    expanded: false
                ),
            ]
        default:
            return []
        }
    }

    private mutating func appendAssistantDelta(
        _ object: [String: KeroJSONValue]
    ) -> [ChatTimelineItem] {
        let id = object["itemId"]?.stringValue ?? UUID().uuidString
        let delta = object["delta"]?.stringValue ?? ""
        assistantText[id, default: ""].append(delta)
        return [.assistant(id: id, text: assistantText[id] ?? delta)]
    }

    private func upsertReasoning(
        _ object: [String: KeroJSONValue]
    ) -> [ChatTimelineItem] {
        let id = object["itemId"]?.stringValue ?? UUID().uuidString
        let delta = object["delta"]?.stringValue
            ?? object["text"]?.stringValue
            ?? ""
        return [.reasoning(id: id, summary: delta, expanded: false)]
    }

    private mutating func replaceTurnFiles(
        _ object: [String: KeroJSONValue]
    ) -> [ChatTimelineItem] {
        let turnID = object["turnId"]?.stringValue ?? "turn"
        let diff = object["diff"]?.stringValue ?? ""
        let files = filesFromUnifiedDiff(diff)
        filesByTurn[turnID] = files
        return [.turnFiles(id: "files-\(turnID)", files: files)]
    }

    private func shouldDrop(_ object: [String: KeroJSONValue]) -> Bool {
        if let source = object["source"]?.stringValue, source == "subAgent" {
            return true
        }
        if let threadSource = object["threadSource"]?.stringValue,
           threadSource == "memory_consolidation" {
            return true
        }
        if let threadID = object["threadId"]?.stringValue,
           droppedThreadIDs.contains(threadID) {
            return true
        }
        return false
    }

    private func textContent(_ value: KeroJSONValue?) -> String? {
        guard let parts = value?.arrayValue else {
            return value?.stringValue
        }
        let texts = parts.compactMap { part -> String? in
            if let text = part.stringValue { return text }
            return part.objectValue?["text"]?.stringValue
        }
        if texts.isEmpty { return nil }
        return texts.joined()
    }

    private func reasoningSummary(_ item: [String: KeroJSONValue]) -> String {
        if let summary = item["summary"]?.arrayValue {
            let texts = summary.compactMap { $0.stringValue ?? $0.objectValue?["text"]?.stringValue }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        if let content = item["content"]?.arrayValue {
            let texts = content.compactMap { $0.stringValue ?? $0.objectValue?["text"]?.stringValue }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return item["text"]?.stringValue ?? ""
    }

    private func fileChanges(_ value: KeroJSONValue?) -> [ChatTurnFile] {
        guard let changes = value?.arrayValue else { return [] }
        return changes.compactMap { change in
            guard let object = change.objectValue else { return nil }
            let path = object["path"]?.stringValue ?? ""
            let diff = object["diff"]?.stringValue ?? ""
            let counts = ChatTimelinePreview.diffLineCounts(diff)
            return ChatTurnFile(path: path, added: counts.added, removed: counts.removed)
        }
    }

    private func filesFromUnifiedDiff(_ diff: String) -> [ChatTurnFile] {
        var files: [ChatTurnFile] = []
        var currentPath: String?
        var added = 0
        var removed = 0
        func flush() {
            if let currentPath {
                files.append(ChatTurnFile(path: currentPath, added: added, removed: removed))
            }
            currentPath = nil
            added = 0
            removed = 0
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                var path = String(line.dropFirst(4))
                if path.hasPrefix("b/") { path.removeFirst(2) }
                currentPath = path
                continue
            }
            if line.hasPrefix("diff --git ") {
                flush()
                continue
            }
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                continue
            }
            if line.hasPrefix("+") { added += 1 }
            else if line.hasPrefix("-") { removed += 1 }
        }
        flush()
        return files
    }

    private func idKey(_ id: JSONRPCID) -> String {
        switch id {
        case .number(let value): return String(value)
        case .string(let value): return value
        }
    }
}
