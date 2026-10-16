import AppKit

// The assistant's edit tool runs as `Draft mcp`, spawned by Claude Code or Codex.
if CommandLine.arguments.dropFirst().first == "mcp" {
    EditServer.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
