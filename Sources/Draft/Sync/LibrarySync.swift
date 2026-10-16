import AppKit

// Git sync for the library folder. The folder is the repository; the system git runs as a
// subprocess on one serial background queue. See docs/sync.md.
enum SyncState: Equatable {
    case off                        // SyncEnabled is false
    case syncing
    case local(Date?)               // no SyncRemote; last local commit
    case synced(Date)               // last successful pull + push
    case offline(String)            // remote unreachable; local commits continue
    case conflict([String])         // conflict copies written; remote sync paused until resume()
    case failed(String)             // git missing or an unexpected git error; retried next cycle
}

final class LibrarySync {
    static let didChange = Notification.Name("LibrarySyncDidChange")
    static let shared = LibrarySync()

    // Main thread only.
    private(set) var state: SyncState = .off

    var commitDelay: TimeInterval = 30
    var pullInterval: TimeInterval = 300
    var launchDelay: TimeInterval = 3

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "library.sync", qos: .utility)
    // Everything below is touched only on `queue`.
    private var root: URL?
    private var git: URL?
    private var identity: [String] = []
    private var pendingCommit: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var paused = false
    private var lastCommit: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var enabled: Bool { defaults.bool(forKey: "SyncEnabled") }
    private var remote: String? {
        let value = defaults.string(forKey: "SyncRemote")?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }

    // MARK: - API

    // Returns immediately; the first sync runs `launchDelay` seconds later on a background queue.
    func start(libraryURL: URL) {
        queue.async {
            self.root = libraryURL.standardizedFileURL
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.launchDelay, repeating: self.pullInterval, leeway: .seconds(10))
            timer.setEventHandler { self.cycle() }
            timer.resume()
            self.timer = timer
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            self.syncNow(after: 5)  // give the network a moment
        }
    }

    // Call after a document is written. Commits `commitDelay` seconds after the last save.
    func noteSaved(url: URL) {
        queue.async {
            guard self.root != nil else { return }  // `url` may be NSDocument's temporary file; `git add -A` finds the change
            self.pendingCommit?.cancel()
            let work = DispatchWorkItem { self.pendingCommit = nil; self.commitOnly() }
            self.pendingCommit = work
            self.queue.asyncAfter(deadline: .now() + self.commitDelay, execute: work)
        }
    }

    func syncNow(after delay: TimeInterval = 0) {
        if delay > 0 { queue.asyncAfter(deadline: .now() + delay) { self.cycle() } } else { queue.async { self.cycle() } }
    }

    // Leaves the conflict state and pushes the resolved history.
    func resume() {
        queue.async { self.paused = false; self.cycle() }
    }

    // Commits pending changes before quitting. Blocks the caller for at most a few seconds.
    func flush() {
        let done = DispatchSemaphore(value: 0)
        queue.async { self.pendingCommit?.cancel(); self.commitOnly(); done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    // MARK: - Cycle

    private func commitOnly() {
        guard enabled, prepare() else { return }
        commit()
        if remote == nil { publish(.local(lastCommit)) }
    }

    private func cycle(retry: Bool = true) {
        guard root != nil else { return }
        guard enabled else { publish(.off); return }
        guard prepare() else { return }
        commit()
        guard !paused else { return }
        guard let remote else { publish(.local(lastCommit)); return }
        publish(.syncing)

        let current = run(["remote", "get-url", "origin"])
        if !current.ok { _ = run(["remote", "add", "origin", remote]) }
        else if current.text != remote { _ = run(["remote", "set-url", "origin", remote]) }

        let head = run(["symbolic-ref", "--short", "HEAD"])
        guard head.ok else { publish(.failed(L("HEAD is detached"))); return }
        let branch = head.text
        let upstream = "refs/remotes/origin/\(branch)"

        let fetch = run(["fetch", "--prune", "origin"], timeout: 60)
        guard fetch.ok else { publish(.offline(fetch.errorLine)); return }

        let unborn = !run(["rev-parse", "-q", "--verify", "HEAD"]).ok
        if run(["rev-parse", "-q", "--verify", upstream]).ok {
            if unborn {
                // Empty library on a new machine: take the remote branch. Refuses to overwrite untracked files.
                let checkout = run(["checkout", "-q", "-B", branch, "--track", "origin/\(branch)"])
                guard checkout.ok else { publish(.failed(checkout.errorLine)); return }
            } else if !integrate(upstream: upstream) {
                return
            }
        } else if unborn {
            publish(.local(lastCommit))  // nothing anywhere yet
            return
        }

        let push = run(["push", "-q", "-u", "origin", "HEAD:refs/heads/\(branch)"], timeout: 60)
        if !push.ok {
            // Rejected: the remote moved after the fetch. Rebase once more right away.
            if push.err.contains("rejected") && retry { cycle(retry: false); return }
            publish(push.err.contains("rejected") ? .failed(push.errorLine) : .offline(push.errorLine))
            return
        }
        publish(.synced(Date()))
    }

    // Opens the repository: finds git, `git init` on first use, and clears what a crash left behind.
    private func prepare() -> Bool {
        guard let root else { return false }
        if git == nil {
            git = LibrarySync.findGit()
            guard git != nil else { publish(.failed(L("git is not installed"))); return false }
            identity = run(["config", "user.email"]).text.isEmpty ? ["-c", "user.name=Draft", "-c", "user.email=draft@localhost"] : []
        }
        let dotGit = root.appendingPathComponent(".git")
        if !FileManager.default.fileExists(atPath: dotGit.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let initialize = run(["init", "-q", "-b", "main"])
            guard initialize.ok else { publish(.failed(initialize.errorLine)); return false }
            let exclude = dotGit.appendingPathComponent("info/exclude")
            try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(".DS_Store\n*.icloud\n".utf8).write(to: exclude)
        }
        removeStaleLock(dotGit)
        if FileManager.default.fileExists(atPath: dotGit.appendingPathComponent("rebase-merge").path)
            || FileManager.default.fileExists(atPath: dotGit.appendingPathComponent("rebase-apply").path) {
            abortRebase()
        }
        return true
    }

    private func removeStaleLock(_ dotGit: URL) {
        let lock = dotGit.appendingPathComponent("index.lock")
        guard FileManager.default.fileExists(atPath: lock.path) else { return }
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "git"]
        pgrep.standardOutput = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return }
        pgrep.waitUntilExit()
        if pgrep.terminationStatus != 0 { try? FileManager.default.removeItem(at: lock) }  // 1 = no git process
    }

    private func commit() {
        _ = run(["add", "-A"])
        let staged = run(["diff", "--cached", "--name-only", "-z"])
        let names = staged.out.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard !names.isEmpty else { return }
        let shown = names.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        let message = names.count > 3 ? "Update \(shown) and \(names.count - 3) more" : "Update \(shown)"
        if run(identity + ["commit", "-q", "--no-verify", "-m", message]).ok { lastCommit = Date() }
    }

    // MARK: - Rebase and conflicts

    // Rebases local commits onto the remote branch. Files that changed on both sides keep the local
    // text; the remote text goes next to them as `Name (conflict YYYY-MM-DD).ext`.
    private func integrate(upstream: String) -> Bool {
        guard let root else { return false }
        let remoteCommit = run(["rev-parse", upstream]).text
        if run(["merge-base", "--is-ancestor", remoteCommit, "HEAD"]).ok { return true }  // nothing new

        // Ask open documents to hold their saves while git rewrites the files the remote changed.
        let changed = run(["diff", "--name-only", "-z", "HEAD", remoteCommit]).out.split(separator: 0)
            .map { root.appendingPathComponent(String(decoding: $0, as: UTF8.self)) }
        var result = true
        coordinatedWrite(changed) {
            // A save that landed after commit() is committed now; a dirty tree would stop the rebase.
            self.commit()
            guard self.run(["status", "--porcelain"]).text.isEmpty else { result = false; return }
            result = self.rebase(onto: remoteCommit)
        }
        return result
    }

    private func rebase(onto remoteCommit: String) -> Bool {
        var step = run(["rebase", "-q", remoteCommit])
        var copies: [String] = []
        var rounds = 0
        while !step.ok {
            rounds += 1
            let conflicted = run(["diff", "--name-only", "-z", "--diff-filter=U"]).out.split(separator: 0)
                .map { String(decoding: $0, as: UTF8.self) }
            guard !conflicted.isEmpty, rounds < 100 else {
                let reason = step.errorLine
                abortRebase()
                publish(.failed(reason))
                return false
            }
            for path in conflicted {
                guard let copy = keepBoth(path, remoteCommit: remoteCommit) else {
                    abortRebase()
                    publish(.failed(String(format: L("Could not resolve %@"), path)))
                    return false
                }
                if !copy.isEmpty && !copies.contains(copy) { copies.append(copy) }
            }
            // A local deletion undone by the remote edit leaves nothing to commit.
            let empty = run(["diff", "--cached", "--quiet"]).ok
            step = run(["-c", "core.editor=true"] + identity + ["rebase", empty ? "--skip" : "--continue"])
        }
        if !copies.isEmpty {
            paused = true
            publish(.conflict(copies))
            return false
        }
        return true
    }

    // Resolves one conflicted path. Returns the name to report: the conflict copy, or the file itself when
    // it was deleted on one side and kept; "" when nothing needs reporting; nil on failure.
    private func keepBoth(_ path: String, remoteCommit: String) -> String? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(path)
        let local = blob(":3:\(path)")              // the local commit being replayed
        let remote = blob("\(remoteCommit):\(path)")
        var copyName = ""
        do {
            if let local {
                try local.write(to: url, options: .atomic)
                if remote == nil { copyName = url.lastPathComponent }  // deleted there, edited here
                if let remote, remote != local {
                    let copy = LibrarySync.conflictURL(for: url, content: remote)
                    if !FileManager.default.fileExists(atPath: copy.path) { try remote.write(to: copy, options: .atomic) }
                    copyName = copy.lastPathComponent
                    guard run(["add", "--", String(copy.path.dropFirst(root.path.count + 1))]).ok else { return nil }
                }
            } else if let remote {
                try remote.write(to: url, options: .atomic)  // deleted here, edited there: keep the edit
                copyName = url.lastPathComponent
            } else {
                return run(["rm", "-q", "--cached", "--ignore-unmatch", "--", path]).ok ? "" : nil
            }
        } catch {
            return nil
        }
        return run(["add", "--", path]).ok ? copyName : nil
    }

    private func blob(_ spec: String) -> Data? {
        let r = run(["cat-file", "blob", spec])
        return r.ok ? r.out : nil
    }

    // `Name (conflict 2026-10-14).txt`, numbered when a different copy already has that name.
    // An existing copy with the same content is reused, so a repeated conflict adds no new files.
    static func conflictURL(for url: URL, content: Data) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = "\(url.deletingPathExtension().lastPathComponent) (conflict \(formatter.string(from: Date())))"
        for n in 1... {
            let stem = n == 1 ? base : "\(base) \(n)"
            let candidate = folder.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
            guard let existing = try? Data(contentsOf: candidate) else { return candidate }
            if existing == content { return candidate }
        }
        fatalError()
    }

    // Keeps the working tree as it is: anything git would reset is written back after the abort.
    private func abortRebase() {
        guard let root else { return }
        let dirty = run(["diff", "--name-only", "-z", "--diff-filter=M"]).out.split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
        let unmerged = Set(run(["diff", "--name-only", "-z", "--diff-filter=U"]).out.split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) })
        let saved = dirty.filter { !unmerged.contains($0) }
            .compactMap { path in (try? Data(contentsOf: root.appendingPathComponent(path))).map { (path, $0) } }
        _ = run(["rebase", "--abort"])
        for (path, data) in saved { try? data.write(to: root.appendingPathComponent(path), options: .atomic) }
    }

    private func coordinatedWrite(_ urls: [URL], _ body: @escaping () -> Void) {
        guard !urls.isEmpty else { body(); return }
        let done = DispatchSemaphore(value: 0)
        let operations = OperationQueue()
        NSFileCoordinator(filePresenter: nil).coordinate(with: urls.map { .writingIntent(with: $0) }, queue: operations) { _ in
            body()
            done.signal()
        }
        done.wait()
    }

    // MARK: - git

    private struct Result {
        let status: Int32
        let out: Data
        let err: String
        var ok: Bool { status == 0 }
        var text: String { String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        var errorLine: String {
            err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "git exited \(status)"
        }
    }

    private func run(_ args: [String], timeout: TimeInterval = 30) -> Result {
        guard let git, let root else { return Result(status: -1, out: Data(), err: "no repository") }
        let process = Process()
        process.executableURL = git
        process.currentDirectoryURL = root
        process.arguments = ["-c", "core.quotepath=false", "-c", "commit.gpgsign=false"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes -oConnectTimeout=10"
        env["GIT_EDITOR"] = "true"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: -1, out: Data(), err: error.localizedDescription) }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errData = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        killer.cancel()
        return Result(status: process.terminationStatus, out: outData, err: String(decoding: errData, as: UTF8.self))
    }

    // Never /usr/bin/git: without developer tools that shim opens the "install developer tools" dialog.
    // /usr/local/bin is skipped too; on this Mac it holds a leftover Intel Homebrew that cannot run.
    private static func findGit() -> URL? {
        let candidates = ["/opt/homebrew/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["--version"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    private func publish(_ state: SyncState) {
        DispatchQueue.main.async {
            guard self.state != state else { return }
            self.state = state
            NotificationCenter.default.post(name: LibrarySync.didChange, object: self)
        }
    }
}
