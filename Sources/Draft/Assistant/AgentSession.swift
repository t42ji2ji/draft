import Foundation

// A proposed change from `propose_edit`, shown as a card until the user applies or skips it.
final class EditProposal {
    enum State: String { case pending, applied, skipped, missing }
    let file: String?   // relative to the library; nil for the open document
    let find: String
    let replace: String
    let reason: String
    var state = State.pending
    var reported = false   // the agent has been told what became of it

    init(file: String?, find: String, replace: String, reason: String) {
        self.file = file
        self.find = find
        self.replace = replace
        self.reason = reason
    }
}

// One conversation with Claude Code or Codex: one process per turn, continued with --resume / `exec resume`.
final class AgentSession {
    // What the user had selected when sending: where (file and lines) and the text.
    struct Quote {
        let label: String
        let text: String
    }

    enum Kind {
        case user(String, quote: Quote?)
        case assistant(String, streaming: Bool)
        case tool(String, running: Bool, failed: Bool)
        case error(String)
        case edit(EditProposal)
    }

    struct Entry {
        let key: String?
        var kind: Kind
    }

    private(set) var entries: [Entry] = []
    private(set) var running = false
    private(set) var backend: AgentBackend {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "AssistantBackend") }
    }
    // Per backend; empty is the CLI's default. Changing it keeps the conversation.
    var model: String {
        get { UserDefaults.standard.string(forKey: "AssistantModel." + backend.rawValue) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "AssistantModel." + backend.rawValue) }
    }
    private(set) var id = UUID()
    // Called on the main thread: an entry was added or changed (its index), nil for a reload or a running change.
    var onChange: ((Int?) -> Void)?

    private var sessionID: String?
    private var process: Process?
    private var run = 0
    private var streamed: Set<String> = []
    private var sawResult = false
    private var silentError: String?
    private static let launchers = resolve()   // once, thread-safe (static lets are lazy)

    init() {
        backend = AgentBackend(rawValue: UserDefaults.standard.string(forKey: "AssistantBackend") ?? "") ?? .claude
        // The last conversation comes back after a relaunch.
        if let current = UserDefaults.standard.string(forKey: "AssistantConversation").flatMap(UUID.init(uuidString:)) {
            load(current)
        }
    }

    // Cards decided since the agent last heard, marked as told.
    private func takeOutcomes() -> [String] {
        entries.compactMap {
            guard case .edit(let e) = $0.kind, e.state != .pending, !e.reported else { return nil }
            e.reported = true
            return "\(e.state == .applied ? "applied" : e.state == .skipped ? "skipped" : "could not apply (text not found)"): \(e.reason)"
        }
    }

    // A new, empty conversation; the current one stays in the history.
    func newConversation() {
        cancel()
        entries = []
        sessionID = nil
        streamed = []
        id = UUID()
        UserDefaults.standard.removeObject(forKey: "AssistantConversation")
        onChange?(nil)
    }

    // Sessions don't carry over between the CLIs, so a non-empty conversation starts over.
    func switchBackend(_ new: AgentBackend) {
        guard new != backend else { return }
        if !entries.isEmpty { newConversation() }
        backend = new
        onChange?(nil)
    }

    func cancel() {
        guard running else { return }
        run += 1   // drop whatever the old process still prints
        process?.terminate()
        process = nil
        finishTurn()
    }

    // `shown` goes in the transcript; `prompt` (with the @ references' text) goes to the CLI.
    func send(shown: String, quote: Quote?, prompt: String, system: String) {
        guard !running else { return }
        let new = takeOutcomes()
        let prompt = new.isEmpty ? prompt : "(Since your last reply the user \(new.joined(separator: "; ")).)\n\n" + prompt
        append(.user(shown, quote: quote))
        running = true
        sawResult = false
        silentError = nil
        run += 1
        let run = run, backend = backend
        onChange?(nil)
        DispatchQueue.global().async {
            let launcher = Self.launchers[backend]
            DispatchQueue.main.async {
                guard run == self.run else { return }
                guard let launcher else {
                    self.append(.error(backend == .claude
                        ? L("Claude Code not found. Install it and run claude in Terminal to sign in, then try again.")
                        : L("Codex not found. Install the Codex CLI and sign in, then try again.")))
                    self.finishTurn()
                    return
                }
                self.start(launcher, backend: backend, prompt: prompt, system: system, run: run)
            }
        }
    }

    // Blocks on the first call while the login shell answers; call it off the main thread first.
    static func available(_ backend: AgentBackend) -> Bool { launchers[backend] != nil }

    // MARK: - Process

    struct Launcher {
        var executable: String
        var path: String
    }

    // Apps started from Finder get a minimal PATH; ask the login shell, then the usual install locations.
    private static func resolve() -> [AgentBackend: Launcher] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude; command -v codex; print -r -- $PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var lines: [String] = []
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        let home = NSHomeDirectory()
        let path = lines.last { $0.contains(":") } ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        // nvm installs (npm i -g) only reach PATH from .zshrc; newest Node version first.
        let nvm = "\(home)/.nvm/versions/node"
        let npm = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin/codex" }
        let fallbacks: [AgentBackend: [String]] = [
            .claude: ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
            .codex: npm + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"],
        ]
        var result: [AgentBackend: Launcher] = [:]
        for backend in AgentBackend.allCases {
            let candidates = lines.filter { $0.hasSuffix("/" + backend.rawValue) } + fallbacks[backend, default: []]
            guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { continue }
            result[backend] = Launcher(executable: exe, path: (exe as NSString).deletingLastPathComponent + ":" + path)
        }
        return result
    }

    private var editServer: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    // Read-only file tools, plus Draft's propose_edit; nothing else. Reads are not pre-approved, so only the library
    // (the working directory) can be read: Claude Code allows that by default and -p denies the rest.
    private func claudeArguments(system: String) -> [String] {
        let mcp: [String: Any] = ["mcpServers": [AgentStream.mcpServer: ["command": editServer, "args": ["mcp"]]]]
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--strict-mcp-config", "--mcp-config", AgentStream.json(mcp),
                    "--tools", "Read,Grep,Glob",
                    "--allowedTools", "mcp__\(AgentStream.mcpServer)__propose_edit",
                    "--setting-sources", "project",
                    "--append-system-prompt", system]
        if !model.isEmpty { args += ["--model", model] }
        if let sessionID { args += ["--resume", sessionID] }
        return args
    }

    // Shell stays on (Codex reads files with it) inside a read-only sandbox; the user's config.toml is ignored.
    private func codexArguments(system: String) -> [String] {
        func toml(_ s: String) -> String {
            // A JSON string literal is a valid TOML basic string once slashes are left unescaped.
            let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        let server = "mcp_servers.\(AgentStream.mcpServer)"
        var args = ["exec"]
        if sessionID != nil { args.append("resume") }
        args += ["--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                 "-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\""]
        for feature in ["apps", "plugins", "browser_use", "browser_use_external", "in_app_browser", "computer_use",
                        "image_generation", "multi_agent"] {
            args += ["--disable", feature]
        }
        args += ["-c", "\(server).command=\(toml(editServer))",
                 "-c", "\(server).args=[\"mcp\"]",
                 "-c", "\(server).default_tools_approval_mode=\"approve\"",
                 "-c", "developer_instructions=\(toml(system))"]
        if !model.isEmpty { args += ["-c", "model=\(toml(model))"] }
        if let sessionID { args.append(sessionID) }
        args.append("-")
        return args
    }

    private func start(_ launcher: Launcher, backend: AgentBackend, prompt: String, system: String, run: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launcher.executable)
        p.arguments = backend == .claude ? claudeArguments(system: system) : codexArguments(system: system)
        p.currentDirectoryURL = Library.rootURL
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = launcher.path
        p.environment = env
        // The prompt goes through stdin so text starting with "-" is never read as an option.
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        do {
            try p.run()
        } catch {
            append(.error(String(format: L("Couldn't start %@: %@"), backend.title, error.localizedDescription)))
            finishTurn()
            return
        }
        process = p
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        // stderr is drained on its own thread so a chatty child cannot stall.
        var errors = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errors = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        DispatchQueue.global().async {
            var buffer = AgentStream.LineBuffer()
            let out = stdout.fileHandleForReading
            while true {
                let data = out.availableData
                let lines = data.isEmpty ? buffer.finish() : buffer.append(data)
                let events = backend == .claude
                    ? lines.map(AgentStream.parse).filter { $0 != .ignored }
                    : lines.flatMap(AgentStream.parseCodex).map { $0.scoped("\(run)/") }
                if !events.isEmpty {
                    DispatchQueue.main.async { events.forEach { self.handle($0, run: run) } }
                }
                if data.isEmpty { break }
            }
            p.waitUntilExit()
            group.wait()
            let status = p.terminationStatus
            let text = String(decoding: errors, as: UTF8.self)
            DispatchQueue.main.async { self.exited(backend, status: status, stderr: text, run: run) }
        }
    }

    private func exited(_ backend: AgentBackend, status: Int32, stderr: String, run: Int) {
        guard run == self.run else { return }
        process = nil
        if !sawResult || silentError != nil {
            let line = stderr.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            append(.error(line.map { String($0.prefix(300)) } ?? silentError ?? String(format: L("%@ exited (code %ld)"), backend.title, Int(status))))
        }
        finishTurn()
    }

    private func finishTurn() {
        running = false
        defer { save() }
        for i in entries.indices {
            switch entries[i].kind {
            case .assistant(let text, true): entries[i].kind = .assistant(text, streaming: false)
            case .tool(let label, true, let failed): entries[i].kind = .tool(label, running: false, failed: failed)
            default: continue
            }
            onChange?(i)
        }
        onChange?(nil)
    }

    private func append(_ kind: Kind, key: String? = nil) {
        entries.append(Entry(key: key, kind: kind))
        onChange?(entries.count - 1)
    }

    // MARK: - Stream events

    private func handle(_ event: AgentEvent, run: Int) {
        guard run == self.run else { return }
        switch event {
        case .initialized(let session, let mcp):
            sessionID = session
            if let mcp { append(.error(String(format: L("Draft's edit tool didn't connect (%@), so this turn can only reply in text."), mcp))) }

        case .textDelta(let message, let index, let text):
            streamed.insert(message)
            let key = "\(message)#\(index)"
            if let i = entries.lastIndex(where: { $0.key == key }), case .assistant(let old, true) = entries[i].kind {
                entries[i].kind = .assistant(old + text, streaming: true)
                onChange?(i)
            } else {
                append(.assistant(text, streaming: true), key: key)
            }

        case .assistant(let message, let blocks):
            for block in blocks {
                switch block {
                case .text(let text):
                    // With deltas, each full block finalizes the oldest still-streaming block of that message.
                    if streamed.contains(message) {
                        if let i = entries.firstIndex(where: {
                            guard $0.key?.hasPrefix(message + "#") == true, case .assistant(_, true) = $0.kind else { return false }
                            return true
                        }) {
                            entries[i].kind = .assistant(text, streaming: false)
                            onChange?(i)
                        }
                    } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        append(.assistant(text, streaming: false), key: message)
                    }
                case .toolUse(let use):
                    guard !entries.contains(where: { $0.key == use.id }) else { continue }
                    toolUse(use)
                }
            }

        case .toolResult(let id, let isError, _):
            if let i = entries.firstIndex(where: { $0.key == id }), case .tool(let label, _, _) = entries[i].kind {
                entries[i].kind = .tool(label, running: false, failed: isError)
                onChange?(i)
            }

        case .result(let session, let isError, let subtype, let text):
            sawResult = true
            if let session { sessionID = session }
            if isError || subtype != "success" {
                if text.isEmpty { silentError = subtype } else { append(.error(String(text.prefix(300)))) }
            }

        case .failure(let text):
            append(.error(String(text.prefix(300))))

        case .ignored:
            break
        }
    }

    private func toolUse(_ use: AgentEvent.ToolUse) {
        let input = AgentStream.object(use.input)
        if use.name.hasSuffix("propose_edit") {
            guard let find = input["find"] as? String, !find.isEmpty else { return }
            let file = (input["file"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            append(.edit(EditProposal(file: file, find: find, replace: input["replace"] as? String ?? "",
                                      reason: input["reason"] as? String ?? "")), key: use.id)
            return
        }
        append(.tool(Self.activity(use.name, input), running: true, failed: false), key: use.id)
    }

    // A short line for what the agent is doing.
    private static func activity(_ tool: String, _ input: [String: Any]) -> String {
        let name = { (path: Any?) in ((path as? String).map { ($0 as NSString).lastPathComponent }) ?? "" }
        switch tool {
        case "Read": return String(format: L("Read %@"), name(input["file_path"]))
        case "Grep": return String(format: L("Search “%@”"), input["pattern"] as? String ?? "")
        case "Glob": return String(format: L("Find files %@"), input["pattern"] as? String ?? "")
        case "Bash": return String(format: L("Run %@"), String((input["command"] as? String ?? "").prefix(60)))
        default: return tool
        }
    }
}

// MARK: - History

// Each conversation is a JSON file in Application Support/Draft/Assistant; the open one is `AssistantConversation`.
extension AgentSession {
    struct Summary {
        let id: UUID
        let title: String
        let updated: Date
        let backend: AgentBackend
    }

    private struct Saved: Codable {
        var backend: String
        var sessionID: String?
        var updated: Date
        var title: String
        var entries: [SavedEntry]
    }

    private struct SavedEntry: Codable {
        var type: String   // user, assistant, tool, error, edit
        var text: String
        var failed: Bool?
        var file: String?   // a user entry's quote label
        var find: String?   // a user entry's quote text
        var replace: String?
        var state: String?
        var reported: Bool?
    }

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Draft/Assistant", isDirectory: true)
    }

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    func save() {
        guard !entries.isEmpty else { return }
        let saved = Saved(backend: backend.rawValue, sessionID: sessionID, updated: Date(), title: title, entries: entries.map { entry in
            switch entry.kind {
            case .user(let t, let q): return SavedEntry(type: "user", text: t, file: q?.label, find: q?.text)
            case .assistant(let t, _): return SavedEntry(type: "assistant", text: t)
            case .tool(let t, _, let failed): return SavedEntry(type: "tool", text: t, failed: failed)
            case .error(let t): return SavedEntry(type: "error", text: t)
            case .edit(let e): return SavedEntry(type: "edit", text: e.reason, file: e.file, find: e.find, replace: e.replace,
                                                 state: e.state.rawValue, reported: e.reported)
            }
        })
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.file(id), options: .atomic)
        UserDefaults.standard.set(id.uuidString, forKey: "AssistantConversation")
    }

    // The first question, shortened.
    private var title: String {
        for entry in entries { if case .user(let t, _) = entry.kind { return String(t.replacingOccurrences(of: "\n", with: " ").prefix(40)) } }
        return L("Conversation")
    }

    func load(_ id: UUID) {
        guard let data = try? Data(contentsOf: Self.file(id)), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        cancel()
        self.id = id
        backend = AgentBackend(rawValue: saved.backend) ?? .claude
        sessionID = saved.sessionID
        streamed = []
        entries = saved.entries.map { s in
            switch s.type {
            case "user": return Entry(key: nil, kind: .user(s.text, quote: s.find.map { Quote(label: s.file ?? "", text: $0) }))
            case "assistant": return Entry(key: nil, kind: .assistant(s.text, streaming: false))
            case "tool": return Entry(key: nil, kind: .tool(s.text, running: false, failed: s.failed ?? false))
            case "edit":
                let e = EditProposal(file: s.file, find: s.find ?? "", replace: s.replace ?? "", reason: s.text)
                e.state = EditProposal.State(rawValue: s.state ?? "") ?? .pending
                e.reported = s.reported ?? false
                return Entry(key: nil, kind: .edit(e))
            default: return Entry(key: nil, kind: .error(s.text))
            }
        }
        UserDefaults.standard.set(id.uuidString, forKey: "AssistantConversation")
        onChange?(nil)
    }

    // Newest first.
    static func history() -> [Summary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> Summary? in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
            return Summary(id: id, title: saved.title, updated: saved.updated, backend: AgentBackend(rawValue: saved.backend) ?? .claude)
        }.sorted { $0.updated > $1.updated }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.file(id))
        if id == self.id { newConversation() }
    }
}

// MARK: - Models

extension AgentSession {
    // Claude Code's aliases for the latest of each family; Codex's listed models, asked from the CLI.
    // Blocks while Codex answers; call it off the main thread first.
    static func models(for backend: AgentBackend) -> [String] {
        backend == .claude ? ["fable", "opus", "sonnet", "haiku"] : codexModels
    }

    private static let codexModels: [String] = {
        guard let launcher = launchers[.codex] else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launcher.executable)
        p.arguments = ["debug", "models"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = launcher.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        return models.filter { $0["visibility"] as? String == "list" }.compactMap { $0["slug"] as? String }
    }()
}
