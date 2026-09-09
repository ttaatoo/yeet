//
//  ClaudeEventMapper.swift
//  kero
//

import Foundation

/// Projects Claude Code `--output-format stream-json` lines into chat items.
struct ClaudeEventMapper {
    private var assistantText = ""
    private var thinkingText = ""
    private(set) var sessionID: String?

    mutating func push(_ value: KeroJSONValue) -> [ChatTimelineItem] {
        guard let object = value.objectValue else { return [] }
        let type = object["type"]?.stringValue ?? ""
        if let sid = object["session_id"]?.stringValue, !sid.isEmpty {
            sessionID = sid
        }
        switch type {
        case "system":
            if object["subtype"]?.stringValue == "init",
               let sid = object["session_id"]?.stringValue {
                sessionID = sid
            }
            return []
        case "assistant":
            return mapAssistant(object["message"]?.objectValue?["content"])
        case "stream_event":
            return mapStreamEvent(object["event"]?.objectValue ?? [:])
        case "control_request":
            return mapControlRequest(object)
        case "result":
            if object["is_error"]?.boolValue == true {
                let message = object["result"]?.stringValue
                    ?? String(localized: "The Claude turn failed.")
                let id = object["session_id"]?.stringValue ?? "error"
                if message.lowercased().contains("not logged in")
                    || message.lowercased().contains("login") {
                    return [.error(id: id, message: message)]
                }
                return [.error(id: id, message: message), .turnFinished(id: id)]
            }
            let id = object["session_id"]?.stringValue ?? "turn"
            return [.turnFinished(id: id)]
        default:
            return []
        }
    }

    private mutating func mapAssistant(_ content: KeroJSONValue?) -> [ChatTimelineItem] {
        guard let blocks = content?.arrayValue else { return [] }
        var items: [ChatTimelineItem] = []
        for block in blocks {
            let object = block.objectValue ?? [:]
            switch object["type"]?.stringValue {
            case "text":
                let text = object["text"]?.stringValue ?? ""
                assistantText.append(text)
                items.append(.assistant(id: "assistant", text: assistantText))
            case "thinking":
                let text = object["thinking"]?.stringValue ?? object["text"]?.stringValue ?? ""
                thinkingText.append(text)
                items.append(.reasoning(id: "thinking", summary: thinkingText, expanded: false))
            case "tool_use":
                items.append(contentsOf: mapToolUse(object))
            default:
                break
            }
        }
        return items
    }

    private func mapStreamEvent(_ event: [String: KeroJSONValue]) -> [ChatTimelineItem] {
        let delta = event["delta"]?.objectValue ?? [:]
        if delta["type"]?.stringValue == "text_delta" {
            return []
        }
        return []
    }

    private func mapToolUse(_ object: [String: KeroJSONValue]) -> [ChatTimelineItem] {
        let id = object["id"]?.stringValue ?? UUID().uuidString
        let name = object["name"]?.stringValue ?? ""
        let input = object["input"]?.objectValue ?? [:]
        if name == "Bash" {
            return [
                .command(
                    id: id,
                    command: input["command"]?.stringValue ?? name,
                    exitCode: nil,
                    durationMs: nil,
                    outputPreview: "",
                    expanded: false
                ),
            ]
        }
        let path = input["file_path"]?.stringValue
            ?? input["path"]?.stringValue
            ?? name
        return [
            .tool(id: id, path: path, added: 0, removed: 0, status: "inProgress"),
        ]
    }

    private func mapControlRequest(_ object: [String: KeroJSONValue]) -> [ChatTimelineItem] {
        let requestID = object["request_id"]?.stringValue ?? UUID().uuidString
        let request = object["request"]?.objectValue ?? [:]
        guard request["subtype"]?.stringValue == "can_use_tool" else { return [] }
        let tool = request["tool_name"]?.stringValue ?? ""
        let input = request["input"]?.objectValue ?? [:]
        let command = input["command"]?.stringValue
        let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue
        let kind: ChatTimelineItem.Kind = tool == "Bash" ? .command : .fileChange
        let detail = command ?? path ?? tool
        return [
            .approval(
                id: "approval-\(requestID)",
                requestID: .string(requestID),
                kind: kind,
                title: tool,
                detail: detail
            ),
        ]
    }
}
