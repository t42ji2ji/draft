import AppKit

struct LibraryItem {
    let url: URL
    let path: String        // standardized, no trailing slash; the key everywhere in the library
    let parentPath: String
    let isFolder: Bool
    var modified: Date
    let created: Date
    var size: Int
    var excerpt: String
    var hashtags: [String]

    var name: String { url.lastPathComponent }
}

// What the file list is showing.
enum LibrarySource: Equatable {
    case folder(URL)
    case recents
    case hashtag(String)
}

// Scans the library folder off the main thread and watches it with FSEvents. After the first scan, only the
// paths FSEvents reports are re-read (stat + excerpt), coalesced, on the scan queue; the main thread gets a diff.
final class Library {
    static let didChange = Notification.Name("LibraryDidChange")

    // userInfo["change"] of `didChange`. nil means everything may have changed (first scan, full rescan).
    struct Change {
        var upserted: Set<String> = []
        var removed: Set<String> = []
        // Folders were added or removed, or the set of hashtags changed: the sidebar has to rebuild.
        var structural = false
        var paths: Set<String> { upserted.union(removed) }
    }

    static var rootURL: URL {
        if let path = UserDefaults.standard.string(forKey: "LibraryPath") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        // iCloud Drive when it's on (evicted files keep their names and download when read), otherwise Documents.
        let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let base = FileManager.default.fileExists(atPath: iCloudDrive.path)
            ? iCloudDrive : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Draft", isDirectory: true)
        UserDefaults.standard.set(url.path, forKey: "LibraryPath")
        return url.standardizedFileURL
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    static let shared = Library()

    // Main-thread state.
    private(set) var byPath: [String: LibraryItem] = [:]
    private var children: [String: Set<String>] = [:]
    private var childFolders: [String: Set<String>] = [:]  // the sidebar's tree, without a pass over every file
    private var tagCounts: [String: Int] = [:]
    private(set) var loaded = false

    // Scan-queue state.
    private let queue = DispatchQueue(label: "library.scan", qos: .userInitiated)
    private var known: [String: LibraryItem] = [:]
    private var pendingPaths = Set<String>()
    private var pendingFull = false
    private var drainScheduled = false
    private var stream: FSEventStreamRef?
    private var rootPath = ""
    private var realRootPath = ""

    func start() {
        let root = Library.rootURL
        queue.async {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.rootPath = Library.key(root)
            // FSEvents reports real paths; URL's symlink resolution would map /private/tmp back to /tmp.
            self.realRootPath = realpath(root.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root.path
            self.scan()
            DispatchQueue.main.async { self.watch(root) }
        }
    }

    // Re-read these paths now (e.g. a file this app just wrote) instead of waiting for FSEvents.
    func refresh(_ urls: [URL]) {
        let paths = urls.map(Library.key)
        queue.async {
            self.pendingPaths.formUnion(paths)
            self.drain()
        }
    }

    var items: [LibraryItem] { Array(byPath.values) }

    var hashtags: [String] {
        tagCounts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func items(in source: LibrarySource) -> [LibraryItem] {
        switch source {
        case .folder(let url): return (children[Library.key(url)] ?? []).compactMap { byPath[$0] }
        case .recents: return byPath.values.filter { !$0.isFolder }
        case .hashtag(let tag): return byPath.values.filter { $0.hashtags.contains(tag) }
        }
    }

    func subfolders(of url: URL) -> [LibraryItem] {
        (childFolders[Library.key(url)] ?? []).compactMap { byPath[$0] }
    }

    // MARK: - Main-thread state

    // Everything the main thread indexes, built on the scan queue so a full scan costs the main thread nothing.
    private struct Index {
        var byPath: [String: LibraryItem] = [:]
        var children: [String: Set<String>] = [:]
        var childFolders: [String: Set<String>] = [:]
        var tagCounts: [String: Int] = [:]

        init(_ items: [String: LibraryItem]) {
            byPath = items
            for item in items.values {
                children[item.parentPath, default: []].insert(item.path)
                if item.isFolder { childFolders[item.parentPath, default: []].insert(item.path) }
                for tag in item.hashtags { tagCounts[tag, default: 0] += 1 }
            }
        }
    }

    private func replaceAll(_ index: Index) {
        byPath = index.byPath
        children = index.children
        childFolders = index.childFolders
        tagCounts = index.tagCounts
        loaded = true
        NotificationCenter.default.post(name: Library.didChange, object: self)
    }

    private func apply(upserts: [LibraryItem], removals: [String]) {
        var change = Change()
        let tagsBefore = Set(tagCounts.keys)
        for path in removals {
            guard let old = byPath.removeValue(forKey: path) else { continue }
            children[old.parentPath]?.remove(path)
            if old.isFolder {
                change.structural = true
                children[path] = nil
                childFolders[path] = nil
                childFolders[old.parentPath]?.remove(path)
            }
            for tag in old.hashtags { tagCounts[tag, default: 1] -= 1; if tagCounts[tag] == 0 { tagCounts[tag] = nil } }
            change.removed.insert(path)
        }
        for item in upserts {
            if let old = byPath[item.path] {
                for tag in old.hashtags { tagCounts[tag, default: 1] -= 1; if tagCounts[tag] == 0 { tagCounts[tag] = nil } }
            } else {
                children[item.parentPath, default: []].insert(item.path)
                if item.isFolder { change.structural = true; childFolders[item.parentPath, default: []].insert(item.path) }
            }
            for tag in item.hashtags { tagCounts[tag, default: 0] += 1 }
            byPath[item.path] = item
            change.upserted.insert(item.path)
        }
        if Set(tagCounts.keys) != tagsBefore { change.structural = true }
        guard !change.paths.isEmpty else { return }
        NotificationCenter.default.post(name: Library.didChange, object: self, userInfo: ["change": change])
    }

    // MARK: - Scanning (scan queue)

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isHiddenKey, .isPackageKey]
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "mdown", "text", "taskpaper", "fountain", "csv"]

    // Stat one URL; nil if it is not something the library lists. The excerpt is filled in separately.
    private static func stat(_ url: URL) -> LibraryItem? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isHidden != true else { return nil }
        let isFolder = (values.isDirectory ?? false) && values.isPackage != true
        if !isFolder && !textExtensions.contains(url.pathExtension.lowercased()) { return nil }
        let path = key(url)
        return LibraryItem(url: URL(fileURLWithPath: path, isDirectory: isFolder), path: path,
                           parentPath: (path as NSString).deletingLastPathComponent, isFolder: isFolder,
                           modified: values.contentModificationDate ?? .distantPast, created: values.creationDate ?? .distantPast,
                           size: values.fileSize ?? 0, excerpt: "", hashtags: [])
    }

    // Excerpts for many files at once, spread over the cores.
    private static func summarize(_ items: inout [LibraryItem]) {
        let files = items.indices.filter { !items[$0].isFolder }
        var results = [(String, [String])?](repeating: nil, count: files.count)
        results.withUnsafeMutableBufferPointer { out in
            let urls = files.map { items[$0].url }
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in out[i] = summary(of: urls[i]) }
        }
        for (n, i) in files.enumerated() {
            if let (excerpt, tags) = results[n] { items[i].excerpt = excerpt; items[i].hashtags = tags }
        }
    }

    // Everything under `url` (not `url` itself).
    private static func enumerate(_ url: URL) -> [LibraryItem] {
        var found: [LibraryItem] = []
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let child = enumerator?.nextObject() as? URL {
            if let item = stat(child) { found.append(item) }
        }
        return found
    }

    private func scan() {
        var found = Library.enumerate(URL(fileURLWithPath: rootPath, isDirectory: true))
        Library.summarize(&found)
        known = Dictionary(found.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let index = Index(known)
        DispatchQueue.main.async { self.replaceAll(index) }
    }

    private func schedule() {
        guard !drainScheduled else { return }
        drainScheduled = true
        queue.asyncAfter(deadline: .now() + 0.15) { self.drainScheduled = false; self.drain() }
    }

    // Re-stat the pending paths and send the difference to the main thread.
    private func drain() {
        if pendingFull {
            pendingFull = false
            pendingPaths = []
            scan()
            return
        }
        guard !pendingPaths.isEmpty else { return }
        let paths = pendingPaths
        pendingPaths = []
        var upserts: [String: LibraryItem] = [:]
        var removals = Set<String>()
        var parents = Set<String>()

        func remove(_ path: String) {
            guard let old = known.removeValue(forKey: path) else { return }
            removals.insert(path)
            parents.insert(old.parentPath)
            if old.isFolder {
                let prefix = path + "/"
                for p in known.keys where p.hasPrefix(prefix) { known[p] = nil; removals.insert(p) }
            }
        }

        for path in paths where path != rootPath {
            guard path.hasPrefix(rootPath + "/"),
                  !path.dropFirst(rootPath.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            let url = URL(fileURLWithPath: path)
            guard let item = Library.stat(url) else { remove(path); continue }
            // Only inside folders the library lists (not inside packages or hidden folders).
            guard item.parentPath == rootPath || known[item.parentPath]?.isFolder == true else { continue }
            if let old = known[path], old.isFolder == item.isFolder {
                // Same kind as before: only re-read when the file actually changed.
                if old.modified == item.modified && old.size == item.size { continue }
                if item.isFolder {
                    var folder = old; folder.modified = item.modified
                    upserts[path] = folder
                    continue
                }
            } else if known[path] != nil {
                remove(path)
            }
            upserts[path] = item
            parents.insert(item.parentPath)
            // A folder that appeared (created, moved or renamed in) brings its contents with it.
            if item.isFolder && known[path] == nil {
                for child in Library.enumerate(url) where known[child.path] == nil { upserts[child.path] = child }
            }
        }
        // Parent folders' dates move when their entries change.
        for parent in parents where parent != rootPath && upserts[parent] == nil {
            if var folder = known[parent], let item = Library.stat(URL(fileURLWithPath: parent)) {
                folder.modified = item.modified
                upserts[parent] = folder
            }
        }
        var changed = Array(upserts.values)
        Library.summarize(&changed)
        for item in changed { known[item.path] = item }
        let removed = Array(removals.subtracting(upserts.keys))
        guard !changed.isEmpty || !removed.isEmpty else { return }
        DispatchQueue.main.async { self.apply(upserts: changed, removals: removed) }
    }

    private static let hashtag = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_#&/])#([\p{L}\p{N}_][\p{L}\p{N}_\-]*)"#)

    // First ~200 characters with Markdown stripped and lines joined, plus hashtags (iA's snippet).
    static func summary(of url: URL) -> (String, [String])? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return ("Empty Document", []) }
        if data.isEmpty { return ("Empty Document", []) }
        let text = String(decoding: data, as: UTF8.self)
        let excerpt = Library.excerpt(of: text)
        let ns = text as NSString
        var tags: [String] = []
        hashtag.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            // `# Heading` is not a tag, and neither is a `#fff` colour.
            let tag = ns.substring(with: match.range(at: 1))
            if tag.allSatisfy(\.isNumber) { return }
            if !tags.contains(tag) { tags.append(tag) }
        }
        return (String(excerpt.prefix(200)), tags)
    }

    // MARK: - FSEvents

    private func received(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let full = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                                           | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        queue.async {
            for (path, flag) in zip(paths, flags) {
                // FSEvents reports resolved paths (/private/tmp for /tmp); map them back onto the library root.
                var p = path
                if !self.realRootPath.isEmpty, self.realRootPath != self.rootPath, p.hasPrefix(self.realRootPath) {
                    p = self.rootPath + p.dropFirst(self.realRootPath.count)
                }
                // Hidden entries, including everything inside a `.git` folder (the library can be a git repo),
                // are never listed, so their churn doesn't wake the drain.
                if p.hasPrefix(self.rootPath), p.dropFirst(self.rootPath.count).contains("/.") { continue }
                if flag & full != 0 { self.pendingFull = true }
                self.pendingPaths.insert(p)
            }
            self.schedule()
        }
    }

    private func watch(_ root: URL) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            Unmanaged<Library>.fromOpaque(info).takeUnretainedValue().received(paths, flags)
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
