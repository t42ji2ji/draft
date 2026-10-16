import Foundation

// The assistant panel runs the user's own Claude Code or Codex CLI, one process per turn (as in ~/me/mailsift).

enum AgentBackend: String, CaseIterable {
    case claude, codex

    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

// One line of `claude -p --output-format stream-json --verbose --include-partial-messages` or `codex exec --json`,
// reduced to what the panel shows.
enum AgentEvent: Equatable {
    struct ToolUse: Equatable {
        var id: String
        var name: String
        var input: String   // compact JSON; decode with `AgentStream.object`
    }

    enum Block: Equatable {
        case text(String)
        case toolUse(ToolUse)
    }

    // `mcpFailure`: Draft's edit server's status when it did not connect.
    case initialized(sessionID: String, mcpFailure: String?)
    case textDelta(messageID: String, index: Int, text: String)
    case assistant(messageID: String, blocks: [Block])
    case toolResult(toolUseID: String, isError: Bool, text: String)
    case result(sessionID: String?, isError: Bool, subtype: String, text: String)
    case failure(String)
    case ignored
}

enum AgentStream {
    static let mcpServer = "draft"

    static func parse(_ line: String) -> AgentEvent {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
        switch obj["type"] as? String {
        case "system":
            guard obj["subtype"] as? String == "init", let session = obj["session_id"] as? String else { return .ignored }
            let servers = obj["mcp_servers"] as? [[String: Any]] ?? []
            let status = servers.first { $0["name"] as? String == mcpServer }?["status"] as? String
            return .initialized(sessionID: session, mcpFailure: status == "connected" ? nil : status ?? "not started")

        case "stream_event":
            guard let event = obj["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, let index = event["index"] as? Int,
                  let messageID = obj["api_message_id"] as? String else { return .ignored }
            return .textDelta(messageID: messageID, index: index, text: text)

        case "assistant":
            guard let message = obj["message"] as? [String: Any], let id = message["id"] as? String else { return .ignored }
            let blocks: [AgentEvent.Block] = (message["content"] as? [[String: Any]] ?? []).compactMap { block in
                switch block["type"] as? String {
                case "text":
                    return (block["text"] as? String).map { .text($0) }
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                    return .toolUse(.init(id: id, name: name, input: json(block["input"] ?? [String: Any]())))
                default:
                    return nil
                }
            }
            return .assistant(messageID: id, blocks: blocks)

        case "user":
            // Tool results come back as a user message.
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]],
                  let block = content.first(where: { $0["type"] as? String == "tool_result" }),
                  let id = block["tool_use_id"] as? String else { return .ignored }
            return .toolResult(toolUseID: id, isError: block["is_error"] as? Bool ?? false, text: text(block["content"]))

        case "result":
            return .result(sessionID: obj["session_id"] as? String, isError: obj["is_error"] as? Bool ?? false,
                           subtype: obj["subtype"] as? String ?? "", text: obj["result"] as? String ?? "")

        default:
            return .ignored
        }
    }

    // Codex has no text deltas: messages, commands and tool calls arrive as whole items.
    static func parseCodex(_ line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch obj["type"] as? String {
        case "thread.started":
            return (obj["thread_id"] as? String).map { [.initialized(sessionID: $0, mcpFailure: nil)] } ?? []
        case "turn.completed":
            return [.result(sessionID: nil, isError: false, subtype: "success", text: "")]
        case "turn.failed":
            let error = obj["error"] as? [String: Any]
            return [.result(sessionID: nil, isError: true, subtype: "error", text: error?["message"] as? String ?? "")]
        case "item.started", "item.completed":
            guard let item = obj["item"] as? [String: Any], let id = item["id"] as? String else { return [] }
            let completed = obj["type"] as? String == "item.completed"
            switch item["type"] as? String {
            case "agent_message":
                guard completed, let text = item["text"] as? String else { return [] }
                return [.assistant(messageID: id, blocks: [.text(text)])]
            case "mcp_tool_call":
                let tool = item["tool"] as? String ?? ""
                let name = item["server"] as? String == mcpServer ? "mcp__\(mcpServer)__\(tool)" : tool
                let use = AgentEvent.assistant(messageID: id, blocks: [.toolUse(.init(
                    id: id, name: name, input: json(item["arguments"] ?? [String: Any]())))])
                guard completed else { return [use] }
                let error = (item["error"] as? [String: Any])?["message"] as? String
                return [use, .toolResult(toolUseID: id, isError: item["status"] as? String == "failed",
                                         text: error ?? text((item["result"] as? [String: Any])?["content"]))]
            case "command_execution":
                // Codex reads the library with shell commands (read-only sandbox).
                let use = AgentEvent.assistant(messageID: id, blocks: [.toolUse(.init(
                    id: id, name: "Bash", input: json(["command": item["command"] as? String ?? ""])))])
                guard completed else { return [use] }
                return [use, .toolResult(toolUseID: id, isError: (item["exit_code"] as? Int ?? 0) != 0, text: "")]
            case "error":
                return (item["message"] as? String).map { [.failure($0)] } ?? []
            default:
                return []
            }
        default:
            return []
        }
    }

    // Tool result content is a string or a list of `{type: text, text}` parts.
    private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    // Splits a byte stream into lines; one JSON line can arrive over many reads.
    struct LineBuffer {
        private var pending = Data()

        mutating func append(_ data: Data) -> [String] {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }

        mutating func finish() -> [String] {
            defer { pending = Data() }
            return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
        }
    }
}

extension AgentEvent {
    // Codex numbers items per turn (item_0, item_1…); prefixing keeps keys unique across turns.
    func scoped(_ prefix: String) -> AgentEvent {
        switch self {
        case .assistant(let id, let blocks):
            return .assistant(messageID: prefix + id, blocks: blocks.map {
                guard case .toolUse(var use) = $0 else { return $0 }
                use.id = prefix + use.id
                return .toolUse(use)
            })
        case .toolResult(let id, let isError, let text):
            return .toolResult(toolUseID: prefix + id, isError: isError, text: text)
        default:
            return self
        }
    }
}
