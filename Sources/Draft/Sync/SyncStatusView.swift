import AppKit

// A one-line sync status. Clicking it syncs now, or, after a conflict, resumes syncing.
final class SyncStatusView: NSButton {
    static let toolbarIdentifier = NSToolbarItem.Identifier("syncStatus")

    private var observers: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero)
        isBordered = false
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        contentTintColor = .secondaryLabelColor
        lineBreakMode = .byTruncatingTail
        target = self
        action = #selector(clicked)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        observers = [
            NotificationCenter.default.addObserver(forName: LibrarySync.didChange, object: LibrarySync.shared, queue: .main) { [weak self] _ in
                self?.update()
            },
            NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in self?.update() },
        ]
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // A toolbar item holding a new status view.
    static func makeToolbarItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: toolbarIdentifier)
        item.label = L("Sync")
        item.view = SyncStatusView()
        return item
    }

    private func update() {
        let time: (Date?) -> String = { $0.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "" }
        var attention = false
        switch LibrarySync.shared.state {
        case .off:
            title = ""
            toolTip = nil
        case .syncing:
            title = L("Syncing…")
            toolTip = nil
        case .local(let date):
            title = date == nil ? L("Sync|Local") : String(format: L("Committed %@"), time(date))
            toolTip = L("No remote set (SyncRemote). Changes are committed locally.")
        case .synced(let date):
            title = String(format: L("Synced %@"), time(date))
            toolTip = L("Click to sync now.")
        case .offline(let reason):
            title = L("Offline")
            toolTip = reason + "\n" + L("Changes are committed locally and pushed when the remote is reachable. Click to retry.")
        case .conflict(let files):
            title = files.count == 1 ? String(format: L("Conflict: %@"), files[0]) : String(format: L("Conflict: %d files"), files.count)
            toolTip = L("Both versions were kept. The other machine's text is in:") + "\n" + files.joined(separator: "\n")
                + "\n" + L("Syncing is paused. Click to resume.")
            attention = true
        case .failed(let reason):
            title = L("Sync error")
            toolTip = reason + "\n" + L("Click to retry.")
            attention = true
        }
        contentTintColor = attention ? .systemOrange : .secondaryLabelColor
        isHidden = title.isEmpty
    }

    @objc private func clicked() {
        if case .conflict = LibrarySync.shared.state { LibrarySync.shared.resume() } else { LibrarySync.shared.syncNow() }
    }
}
