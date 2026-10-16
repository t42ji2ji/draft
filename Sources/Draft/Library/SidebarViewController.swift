import AppKit

// The library in one column: Locations as a folder tree with the files in it, then Favorites / Hashtags (iA's sidebar
// sections, without Smart Folders). Hashtags expand to their files. Dragging onto a folder moves into it. Shift-click and
// ⌘-click select several rows, which then drag, trash and show in Finder together.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
        enum Kind { case section, placeholder, source(LibrarySource), file(URL) }
        let title: String
        let kind: Kind
        var children: [Node] = []
        init(_ title: String, _ kind: Kind, _ children: [Node] = []) {
            self.title = title; self.kind = kind; self.children = children
        }

        // Stable across rebuilds, for keeping rows expanded.
        var id: String {
            switch kind {
            case .section, .placeholder: return "section:" + title
            case .source(.folder(let url)): return "folder:" + Library.key(url)
            case .source(.recents): return "recents"
            case .source(.hashtag(let tag)): return "tag:" + tag
            case .file(let url): return "file:" + Library.key(url)
            }
        }
    }

    var onOpen: ((URL) -> Void)?
    var onMove: (([URL], URL) -> Void)?
    var onRename: ((URL) -> Void)?
    var onTrash: ((URL) -> Void)?
    static let favoritesKey = "Favorites"
    private static let expandedKey = "SidebarExpanded"
    private let outline = SidebarOutline()
    private var roots: [Node] = []
    private var treePaths = Set<String>()  // files and folders under Locations
    private var currentFile: URL?
    private var selectedID: String?  // the selected row, kept across rebuilds
    private var updatingSelection = false
    // Where ⌘N and New Folder go: the selected folder, or the folder of the selected file.
    private(set) var folder = Library.rootURL
    private var expanded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? ["folder:" + Library.key(Library.rootURL)]) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.expandedKey) }
    }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = ThinScroller()
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 50, left: 0, bottom: 0, right: 0)
        outline.style = .sourceList
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: .init("c"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.onDelete = { [weak self] in
            guard let self else { return }
            self.trash(self.urls(atRows: self.outline.selectedRowIndexes))
        }
        scroll.documentView = outline
        let root = PaletteBackgroundView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        rebuild()
        NotificationCenter.default.addObserver(forName: Library.didChange, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if let change = note.userInfo?["change"] as? Library.Change, !self.needsRebuild(change) { return }
            self.rebuild()
        }
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    // Edits to files already in the tree don't move anything, unless a hashtag is open (its membership follows edits).
    private func needsRebuild(_ change: Library.Change) -> Bool {
        if change.structural || !change.removed.isEmpty { return true }
        if !change.upserted.isSubset(of: treePaths) { return true }
        return expanded.contains { $0.hasPrefix("tag:") }
    }

    private func treeNodes(in url: URL) -> [Node] {
        let byName = { (a: LibraryItem, b: LibraryItem) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        let folders = Library.shared.subfolders(of: url).sorted(by: byName).map { Node($0.name, .source(.folder($0.url)), treeNodes(in: $0.url)) }
        let files = Library.shared.items(in: .folder(url)).filter { !$0.isFolder }.sorted(by: byName).map { Node($0.name, .file($0.url)) }
        return folders + files
    }

    private func fileNodes(_ source: LibrarySource) -> [Node] {
        Library.shared.items(in: source).filter { !$0.isFolder }
            .sorted { $0.modified > $1.modified }
            .map { Node($0.name, .file($0.url)) }
    }

    // MARK: - Favorites (paths in UserDefaults; the app isn't sandboxed, so no bookmarks)

    static var favorites: [String] {
        get { UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: favoritesKey) }
    }

    // Draft renames finishing later; until then their old paths are missing but must not be dropped.
    static var renamesInFlight = 0

    // A favorite whose file or folder is gone (deleted, or renamed outside Draft) is removed for good.
    private func favoriteNodes() -> [Node] {
        var isDir: ObjCBool = false
        var kept: [String] = []
        let nodes = Self.favorites.compactMap { path -> Node? in
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
            kept.append(path)
            let url = URL(fileURLWithPath: path, isDirectory: isDir.boolValue)
            return Node(url.lastPathComponent, isDir.boolValue ? .source(.folder(url)) : .file(url))
        }
        // Not while the library itself is missing (an unmounted drive).
        if kept.count != Self.favorites.count, Self.renamesInFlight == 0, FileManager.default.fileExists(atPath: Library.rootURL.path) {
            Self.favorites = kept
        }
        return nodes
    }

    // Moves and renames made in Draft: favorites at or under `old` follow to `new`.
    static func favoritesMoved(from old: URL, to new: URL) {
        let from = Library.key(old), to = Library.key(new)
        favorites = favorites.map { $0 == from || $0.hasPrefix(from + "/") ? to + $0.dropFirst(from.count) : $0 }
    }

    // Only folders and text files inside the library: the tree can't show folders it doesn't scan.
    private func droppableURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let root = Library.key(Library.rootURL)
        return urls.filter { url in
            let path = Library.key(url)
            return (path == root || path.hasPrefix(root + "/")) && !Self.favorites.contains(path)
                && (url.hasDirectoryPath || Library.shared.byPath[path] != nil)
        }
    }

    // Library items that can move into `folder`: not already there, and not the folder itself or one above it.
    private func movableURLs(_ info: NSDraggingInfo, into folder: URL) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let target = Library.key(folder)
        return urls.filter { url in
            let path = Library.key(url)
            return Library.shared.byPath[path] != nil && (path as NSString).deletingLastPathComponent != target
                && path != target && !target.hasPrefix(path + "/")
        }
    }

    private var locationsSection: Node? { roots.first }
    private var favoritesSection: Node? { roots.first { $0.title == "Favorites" } }

    private func section(of node: Node) -> Node? {
        var top: Any? = node
        while let parent = outline.parent(forItem: top) { top = parent }
        return top as? Node
    }

    // The folder a drop on `node` goes into: the node itself if it's a folder in the tree, else the file's folder.
    private func dropFolder(_ node: Node?) -> Node? {
        guard let node, section(of: node) === locationsSection else { return nil }
        switch node.kind {
        case .source(.folder): return node
        case .file: return outline.parent(forItem: node) as? Node
        default: return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let node = item as? Node
        if let target = dropFolder(node), case .source(.folder(let url)) = target.kind {
            guard !movableURLs(info, into: url).isEmpty else { return [] }
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        guard let section = favoritesSection, !droppableURLs(info).isEmpty else { return [] }
        let inFavorites = node === section || section.children.contains { $0 === node }
        guard inFavorites else { return [] }
        outlineView.setDropItem(section, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let target = dropFolder(item as? Node), case .source(.folder(let url)) = target.kind {
            let urls = movableURLs(info, into: url)
            guard !urls.isEmpty else { return false }
            onMove?(urls, url)
            return true
        }
        let urls = droppableURLs(info)
        guard !urls.isEmpty else { return false }
        addFavorites(urls)
        return true
    }

    func addFavorites(_ urls: [URL]) {
        Self.favorites += urls.map(Library.key).filter { !Self.favorites.contains($0) }
        rebuild()
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        url(of: item as? Node) as NSURL?
    }

    private func url(of node: Node?) -> URL? {
        switch node?.kind {
        case .source(.folder(let url)), .file(let url): return url
        default: return nil
        }
    }

    private func urls(atRows rows: IndexSet) -> [URL] {
        rows.compactMap { url(of: outline.item(atRow: $0) as? Node) }
    }

    // Not the library root, and nothing whose folder is going too (it goes with the folder).
    private func trash(_ urls: [URL]) {
        let paths = Set(urls.map(Library.key))
        for url in urls where Library.key(url) != Library.key(Library.rootURL) {
            var parent = (Library.key(url) as NSString).deletingLastPathComponent
            var covered = false
            while parent.count > 1 { if paths.contains(parent) { covered = true; break }; parent = (parent as NSString).deletingLastPathComponent }
            if !covered { onTrash?(url) }
        }
    }

    // MARK: - Building and selecting

    func rebuild() {
        let root = Library.rootURL
        let location = Node(root.lastPathComponent, .source(.folder(root)), treeNodes(in: root))
        // Section titles stay English (row ids and `favoritesSection` use them); the cells translate them.
        roots = [
            Node("Locations", .section, [location]),
            Node("Favorites", .section, favoriteNodes().nilIfEmpty ?? [Node("Drag folders and files here for quick access", .placeholder)]),
        ]
        let tags = Library.shared.hashtags
        if !tags.isEmpty { roots.append(Node("Hashtags", .section, tags.map { Node($0, .source(.hashtag($0)), fileNodes(.hashtag($0))) })) }
        treePaths = []
        func collect(_ nodes: [Node]) { for n in nodes { if let url = url(of: n) { treePaths.insert(Library.key(url)) }; collect(n.children) } }
        collect([location])

        updatingSelection = true
        defer { updatingSelection = false }
        let open = expanded
        outline.reloadData()
        func expand(_ nodes: [Node]) {
            for n in nodes where !n.children.isEmpty {
                if case .section = n.kind { outline.expandItem(n) } else if open.contains(n.id) { outline.expandItem(n) } else { continue }
                expand(n.children)
            }
        }
        expand(roots)
        // Keep the row that was selected, without scrolling: a rebuild shouldn't move what she's looking at.
        if let selectedID, select(where: { $0.id == selectedID }, scroll: false) { return }
        if let currentFile, select(where: { if case .file(let u) = $0.kind { return Library.key(u) == Library.key(currentFile) }; return false }, scroll: false) { return }
        select(where: { if case .source(.folder(let u)) = $0.kind { return Library.key(u) == Library.key(folder) }; return false }, scroll: false)
    }

    // Highlights the open file in the tree (nil: a never-written draft, which has no row).
    func show(file url: URL?) {
        currentFile = url
        if let url { folder = url.deletingLastPathComponent() }
        updatingSelection = true
        defer { updatingSelection = false; selectedID = (outline.item(atRow: outline.selectedRow) as? Node)?.id }
        guard let url else { outline.deselectAll(nil); return }
        // Opened from Favorites or a hashtag: that row stays selected.
        if case .file(let u) = (outline.item(atRow: outline.selectedRow) as? Node)?.kind, Library.key(u) == Library.key(url) { return }
        if !select(where: { if case .file(let u) = $0.kind { return Library.key(u) == Library.key(url) }; return false }) {
            outline.deselectAll(nil)
        }
    }

    // A folder that was moved keeps being the target for new files.
    func folderMoved(from old: URL, to new: URL) {
        let path = Library.key(folder), from = Library.key(old)
        if path == from || path.hasPrefix(from + "/") { folder = URL(fileURLWithPath: Library.key(new) + path.dropFirst(from.count), isDirectory: true) }
    }

    // Selects the first match under Locations (expanding its parents), then anywhere else.
    @discardableResult
    private func select(where match: (Node) -> Bool, scroll: Bool = true) -> Bool {
        func find(_ nodes: [Node], _ path: [Node]) -> [Node]? {
            for n in nodes {
                if match(n) { return path + [n] }
                if let hit = find(n.children, path + [n]) { return hit }
            }
            return nil
        }
        guard let path = find(roots, []), let node = path.last else { return false }
        for p in path.dropLast() { outline.expandItem(p) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        if outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
        if scroll { outline.scrollRowToVisible(row) }
        return true
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { PaletteRowView() }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    // A shift-click range skips section titles and placeholders.
    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet { row in
            switch (outlineView.item(atRow: row) as? Node)?.kind {
            case .source(.folder), .file: return true
            default: return false
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .section = (item as? Node)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        if case .section = (item as? Node)?.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        switch (item as? Node)?.kind {
        case .source(.folder), .file: return true
        default: return false
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? Node else { return }
        setFolderIcon(node, open: true)
        guard !updatingSelection else { return }
        expanded.insert(node.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? Node else { return }
        setFolderIcon(node, open: false)
        guard !updatingSelection else { return }
        expanded.remove(node.id)
    }

    // A folder row shows an open folder while expanded.
    private func setFolderIcon(_ node: Node, open: Bool) {
        guard case .source(.folder) = node.kind, case let row = outline.row(forItem: node), row >= 0,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return }
        cell.imageView?.image = open ? LibraryStyle.openFolder : NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        // Measured on iA: items 32 pt, placeholder 53 pt. The source list adds ~13 pt before each later section,
        // so later titles get 21.5 pt rows to land where iA's do. Files are tighter, so the tree stays readable.
        guard let node = item as? Node else { return 32 }
        switch node.kind {
        case .placeholder: return 53
        case .section: return node === roots.first ? 24 : 21.5
        case .source: return 32
        case .file: return 26
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch node.kind {
        case .section:
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: L(node.title))
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            cell.textField = label
            pin(label, in: cell, leading: 0, centerOffset: node === roots.first ? 0 : -1.25)
            return cell
        case .placeholder:
            let cell = NSTableCellView()
            let label = NSTextField(wrappingLabelWithString: L(node.title))
            label.font = .systemFont(ofSize: 13)
            label.textColor = .tertiaryLabelColor
            label.isSelectable = false
            pin(label, in: cell, leading: 0)
            return cell
        case .source, .file:
            let cell = SidebarCell()
            cell.onPress = { [weak self, weak node] in
                guard let self, let node else { return }
                let row = self.outline.row(forItem: node)
                guard row >= 0 else { return }
                self.outline.selectRowIndexes([row], byExtendingSelection: false)  // opens a file
                if !node.children.isEmpty { self.activate(node) }
            }
            let symbol: String, tint: NSColor
            switch node.kind {
            case .source(.folder): symbol = "folder.fill"; tint = LibraryStyle.folderTint
            case .source(.hashtag): symbol = "number.circle"; tint = LibraryStyle.hashtagTint
            default: symbol = "doc.text"; tint = LibraryStyle.hashtagTint
            }
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            if case .source(.folder) = node.kind, outline.isItemExpanded(node) { image.image = LibraryStyle.openFolder }
            image.contentTintColor = tint
            image.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            let label = NSTextField(labelWithString: node.title)
            label.font = .systemFont(ofSize: 13)
            label.textColor = LibraryStyle.paletteText
            label.lineBreakMode = .byTruncatingMiddle
            cell.imageView = image
            cell.textField = label
            for v in [image, label] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    private func pin(_ label: NSTextField, in cell: NSView, leading: CGFloat, centerOffset: CGFloat = 0) {
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: centerOffset),
        ])
    }

    // Keyboard selection opens files and picks folders, like a click. Several rows: nothing opens.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, outline.selectedRowIndexes.count == 1,
              let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        selectedID = node.id
        select(node)
    }

    private func select(_ node: Node) {
        switch node.kind {
        case .file(let url):
            if currentFile.map(Library.key) != Library.key(url) { onOpen?(url) }
        case .source(.folder(let url)):
            folder = url
            // A favourite folder shows where it is in the tree.
            if section(of: node) === favoritesSection {
                updatingSelection = true
                defer { updatingSelection = false }
                select(where: { if case .source(.folder(let u)) = $0.kind { return Library.key(u) == Library.key(url) }; return false })
            }
        default: break
        }
    }

    // A click on a folder or a hashtag opens or closes it (not on the disclosure triangle, which does that itself, and not
    // a shift- or ⌘-click, which only selects).
    @objc private func clicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node, !node.children.isEmpty,
              NSApp.currentEvent?.modifierFlags.intersection([.shift, .command]).isEmpty ?? true else { return }
        if case .section = node.kind { return }
        if let event = NSApp.currentEvent, outline.frameOfOutlineCell(atRow: row).contains(outline.convert(event.locationInWindow, from: nil)) { return }
        activate(node)
    }

    private func activate(_ node: Node) {
        if case .file = node.kind { select(node); return }
        guard !node.children.isEmpty else { select(node); return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = outline.clickedRow
        guard let node = outline.item(atRow: clicked) as? Node, let url = url(of: node) else { return }
        // Right-clicking one of several selected rows acts on all of them; Rename and Duplicate need one file.
        let rows = outline.selectedRowIndexes.contains(clicked) ? outline.selectedRowIndexes : [clicked]
        let urls = self.urls(atRows: rows)
        if case .file = node.kind, urls.count == 1 {
            menu.addItem(MenuClosureItem(title: L("Rename…")) { [weak self] in self?.onRename?(url) })
            menu.addItem(MenuClosureItem(title: L("Duplicate")) { Self.duplicate(url) })
        }
        menu.addItem(MenuClosureItem(title: L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(urls) })
        if section(of: node) === favoritesSection {
            menu.addItem(MenuClosureItem(title: L("Remove from Favorites")) { [weak self] in
                let keys = Set(urls.map(Library.key))
                Self.favorites.removeAll { keys.contains($0) }
                self?.rebuild()
            })
        }
        // The library root itself stays.
        guard urls.contains(where: { Library.key($0) != Library.key(Library.rootURL) }) else { return }
        menu.addItem(.separator())
        let trash = MenuClosureItem(title: L("Move to Trash")) { [weak self] in self?.trash(urls) }
        trash.keyEquivalent = "\u{8}"
        trash.keyEquivalentModifierMask = .command
        menu.addItem(trash)
    }

    // "Name copy.txt", then "Name copy 2.txt" (iA, docs/storage.md).
    private static func duplicate(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent + " copy"
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let name = DocumentName.uniqueFileName(stem: stem, ext: ext, existing: existing)
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            Library.shared.refresh([target])
        } catch { NSApp.presentError(error) }
    }
}

// ⌘⌫ moves the selected files and folders to the Trash.
final class SidebarOutline: NSOutlineView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command { onDelete?(); return }
        super.keyDown(with: event)
    }
}

// Sidebar rows are buttons to accessibility.
final class SidebarCell: NSTableCellView {
    var onPress: (() -> Void)?
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { textField?.stringValue }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
