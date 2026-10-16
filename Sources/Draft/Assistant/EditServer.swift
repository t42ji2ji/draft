import Foundation

// `Draft mcp`: a minimal MCP server (JSON-RPC 2.0, one object per line on stdio) with the one tool the assistant
// may change text with. It changes nothing: the panel reads the call from the CLI's stream, shows it as a card,
// and applies it only when the user confirms.
enum EditServer {
    static let tools: [[String: Any]] = [[
        "name": "propose_edit",
        "description": """
            Propose one change to a document for the user to confirm in Draft. Does not change the file. \
            `find` must be copied exactly from the document (enough words to be unique); `replace` is the new text. \
            Keep each proposal to one passage; call once per passage.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "file": ["type": "string", "description": "Path relative to the library; omit for the open document"],
                "find": ["type": "string", "description": "Exact current text to replace"],
                "replace": ["type": "string", "description": "The new text (empty to delete)"],
                "reason": ["type": "string", "description": "A few words: why"],
            ],
            "required": ["find", "replace", "reason"],
        ],
    ]]

    static func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = msg["method"] as? String, let id = msg["id"] else { continue }   // notifications need no reply
            let params = msg["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                           "capabilities": ["tools": [:]],
                           "serverInfo": ["name": AgentStream.mcpServer, "version": "0.1.0"]])
            case "tools/list":
                reply(id, ["tools": tools])
            case "tools/call":
                let known = params["name"] as? String == "propose_edit"
                reply(id, ["content": [["type": "text", "text": known ? "Shown to the user as a card; they will apply or skip it." : "unknown tool"]],
                           "isError": !known])
            case "ping":
                reply(id, [:])
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown method \(method)"]])
            }
        }
    }

    private static func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
