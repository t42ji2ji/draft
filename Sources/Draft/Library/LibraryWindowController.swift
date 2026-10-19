import AppKit

// iA's library window, with the sidebar and file list merged into one tree and the list's column showing the open
// document's headings instead: library | outline | editor in one window. Documents are swapped in and out of the
// one editor (iA's IALibraryWindowController); the window controller is attached to whichever is shown.
final class LibraryWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSToolbarDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    private(set) static var existing: LibraryWindowController?
    static let lastDocumentKey = "LastDocumentPath"

    static func shared() -> LibraryWindowController {
        if let existing { return existing }
        let controller = LibraryWindowController()
        existing = controller
        return controller
    }

    let textView = EditorTextView(usingTextLayoutManager: false)
    private let split = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let outline = DocumentOutlineViewController()
    private let showOutlineButton = NSButton(image: NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: "Show Outline")!,
                                             target: nil, action: nil)
    private var outlineCollapsed: NSKeyValueObservation?
    private let assistant = AssistantViewController()
    private let editor = NSViewController()
    private let scrollView = NSScrollView()
    let formatBar = FormatBar()
    private let titleLabel = TitleField(string: "")
    private var loading = false
    private var needsDefaultSplit = false
    private(set) var bars: BarVisibility?
    // Preview (docs/preview.md): created lazily — WebKit loads on first `preview.view` access.
    let preview = PreviewViewController()
    let previewToolbar = PreviewToolbar()
    private let editorPane = NSView()
    private let titlebarBand = TitlebarBand()
    private var paneConstraints: [NSLayoutConstraint] = []
    private var previewVisible = false

    private var documentHistory: [URL] = []
    private var documentIndex = -1
    private var editorNav: NSSegmentedControl?

    // ⌘N target: the folder selected in the tree, or the open file's folder.
    var newDocumentFolder: URL { sidebar.folder }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true   // the page runs up under the toolbar instead of a white band
        window.isRestorable = false
        window.minSize = NSSize(width: 500, height: 300)
        super.init(window: window)
        window.delegate = self
        buildEditor()
        buildSplit()
        // Toolbar before content: the other order costs ~70 ms at launch (measured).
        buildToolbar()
        window.contentViewController = split
        // The band covers the title bar and fades out just below it.
        titlebarBand.bottomAnchor.constraint(equalTo: (window.contentLayoutGuide as! NSLayoutGuide).topAnchor,
                                             constant: TitlebarBand.fade).isActive = true
        bars = BarVisibility(window: window, bottomBar: formatBar, titlebarBand: titlebarBand, textView: textView, scrollView: scrollView,
                             libraryCollapsed: { [unowned self] in split.splitViewItems[0].isCollapsed })
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        window.setFrameAutosaveName("Library")
        needsDefaultSplit = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames LibraryOutline") == nil
        applyPalette()
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.applyPalette() }
        applyLanguage()
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in self?.applyLanguage() }
        // Warm WebKit up once the window is idle, so the first ▶ doesn't wait seconds for its first page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.previewVisible else { return }
            self.preview.inset = 76
            self.preview.updateNow(text: self.textView.string, documentURL: self.document?.fileURL)
        }
        split.splitView.autosaveName = "LibraryOutline"

        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.setAccessibilityIdentifier("editor")
        textView.configure()

        sidebar.onOpen = { [weak self] in self?.open($0) }
        sidebar.onMove = { [weak self] in self?.move($0, into: $1) }
        sidebar.onRename = { [weak self] url in
            self?.open(url)
            DispatchQueue.main.async { self?.renameCurrentDocument(nil) }
        }
        sidebar.onTrash = { [weak self] in self?.moveToTrash($0) }
        outline.onJump = { [weak self] location in
            guard let self else { return }
            self.textView.setSelectedRange(NSRange(location: location, length: 0))
            self.textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            self.window?.makeFirstResponder(self.textView)
        }
        outline.paper = { [unowned self] in
            (self.textView.typography.lineHeight, self.textView.convert(NSPoint(x: 0, y: self.textView.textContainerOrigin.y), to: nil))
        }
        outline.onCollapse = { [weak self] in self?.toggleOutline(nil) }
        outline.onMove = { [weak self] range, text, caret in
            guard let self, self.textView.shouldChangeText(in: range, replacementString: text) else { return }
            self.textView.textStorage?.replaceCharacters(in: range, with: text)
            self.textView.didChangeText()
            self.textView.undoManager?.setActionName(L("Move Section"))
            self.textView.setSelectedRange(NSRange(location: caret, length: 0))
            self.textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
            self.outline.update(text: self.textView.string)
        }
        assistant.context = { [unowned self] in
            .init(file: libraryPath(document?.fileURL), name: (document as? NSDocument)?.displayName ?? "Untitled",
                  text: textView.string, selection: textView.selectedRange())
        }
        assistant.onApply = { [weak self] in self?.apply($0) }
        assistant.onReveal = { [weak self] in self?.reveal($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Assistant edits

    private func libraryPath(_ url: URL?) -> String? {
        let root = Library.rootURL.standardizedFileURL.path + "/"
        guard let path = url?.standardizedFileURL.path, path.hasPrefix(root) else { return nil }
        return String(path.dropFirst(root.count))
    }

    // Runs `body` with the proposal's document in the editor, opening it first when it's another file.
    private func withDocument(of edit: EditProposal, _ body: @escaping () -> Void) {
        guard let file = edit.file, file != libraryPath(document?.fileURL) else { return body() }
        open(Library.rootURL.appendingPathComponent(file)) { body() }
    }

    // One undoable replacement in the editor; the card says so when the original text is gone.
    private func apply(_ edit: EditProposal) {
        withDocument(of: edit) { [weak self] in
            guard let self else { return }
            let range = (self.textView.string as NSString).range(of: edit.find)
            if range.location == NSNotFound {
                edit.state = .missing
            } else if self.textView.shouldChangeText(in: range, replacementString: edit.replace) {
                self.textView.textStorage?.replaceCharacters(in: range, with: edit.replace)
                self.textView.didChangeText()
                self.textView.undoManager?.setActionName(L("AI Edit"))
                edit.state = .applied
            }
            if edit.file != nil { self.assistant.refreshCards() }
        }
    }

    private func reveal(_ edit: EditProposal) {
        withDocument(of: edit) { [weak self] in
            guard let self else { return }
            let range = (self.textView.string as NSString).range(of: edit.find)
            guard range.location != NSNotFound else { return }
            self.textView.setSelectedRange(range)
            self.textView.scrollRangeToVisible(range)
            self.textView.showFindIndicator(for: range)
        }
    }

    // A palette fixes light or dark, so the window follows it (sidebar and list keep iA's greys); iA's follows the system.
    private func applyPalette() {
        window?.appearance = Palette.current.map { NSAppearance(named: $0.isDark ? .darkAqua : .aqua) } ?? nil
        scrollView.verticalScroller?.needsDisplay = true
        textView.needsDisplay = true
        editor.view.needsDisplay = true
        formatBar.needsDisplay = true
        titlebarBand.needsDisplay = true
        func redraw(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(redraw) }
        redraw(formatBar)   // its separator lines sit inside
        split.splitView.needsDisplay = true
        textView.relayout()   // font weight depends on light/dark
        sidebar.view.needsDisplay = true
        sidebar.rebuild()
        outline.applyPalette()
        assistant.applyPalette()
    }

    // The sidebar, outline, format bar and sync status follow the language themselves.
    private func applyLanguage() {
        showOutlineButton.toolTip = L("Show Outline (⇧⌘O)")
        showOutlineButton.setAccessibilityLabel(L("Show Outline"))
        window?.toolbar?.items.forEach(localize)
        updateTitle()
    }

    // MARK: - Layout

    private func buildEditor() {
        let root = PageView()
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = ThinScroller()
        scrollView.autohidesScrollers = true
        // The page colour comes from `root`: a scroll view that draws its own background gets a white band under the
        // title bar.
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            self?.textView.relayout()
            self?.outline.paperMoved()
        }
        formatBar.onAction = { [weak self] in self?.format($0, $1) }
        for v in [scrollView, formatBar] { v.translatesAutoresizingMaskIntoConstraints = false; editorPane.addSubview(v) }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: editorPane.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor),   // under the bar, so the paper shows when it fades
            formatBar.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            formatBar.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            formatBar.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor),
            formatBar.heightAnchor.constraint(equalToConstant: LibraryStyle.bottomBarHeight),
        ])
        editorPane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(editorPane)
        titlebarBand.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titlebarBand)
        NSLayoutConstraint.activate([
            titlebarBand.topAnchor.constraint(equalTo: root.topAnchor),
            titlebarBand.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebarBand.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        // With the outline folded away, a button at the page's top left brings it back.
        showOutlineButton.isBordered = false
        showOutlineButton.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        showOutlineButton.contentTintColor = LibraryStyle.paletteSecondaryText
        showOutlineButton.target = self
        showOutlineButton.action = #selector(toggleOutline(_:))
        showOutlineButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(showOutlineButton)
        NSLayoutConstraint.activate([
            showOutlineButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            showOutlineButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 58),
        ])
        editor.view = root
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            self?.outline.paperMoved()
            guard let self, self.previewVisible, self.preview.layout == .split else { return }
            self.preview.scroll(toSourceLine: PreviewViewController.topSourceLine(of: self.textView))
        }
        preview.onChangeLayout = { [weak self] layout in
            guard let self else { return }
            self.layoutPanes()
            if layout == .full { self.editorPane.isHidden = true }
        }
        layoutPanes()
    }

    // Editor alone, preview replacing it (Full), or side by side (Split).
    private func layoutPanes() {
        NSLayoutConstraint.deactivate(paneConstraints)
        let root = editor.view
        var c: [NSLayoutConstraint] = [
            editorPane.topAnchor.constraint(equalTo: root.topAnchor),
            editorPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            editorPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        ]
        if previewVisible {
            let page = preview.view
            if page.superview !== root {
                page.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(page, positioned: .below, relativeTo: titlebarBand)
            }
            let split = preview.layout == .split
            // In Full the editor stays underneath until the cross-fade finishes (see togglePreview).
            if split { editorPane.isHidden = false; editorPane.alphaValue = 1 }
            c += [page.topAnchor.constraint(equalTo: root.topAnchor),
                  page.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                  page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                  split ? editorPane.trailingAnchor.constraint(equalTo: root.centerXAnchor)
                        : editorPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                  split ? page.leadingAnchor.constraint(equalTo: editorPane.trailingAnchor)
                        : page.leadingAnchor.constraint(equalTo: root.leadingAnchor)]
        } else {
            if preview.isViewLoaded { preview.view.removeFromSuperview() }
            editorPane.isHidden = false
            c.append(editorPane.trailingAnchor.constraint(equalTo: root.trailingAnchor))
        }
        paneConstraints = c
        NSLayoutConstraint.activate(c)
    }

    private func refreshPreview() {
        guard previewVisible else { return }
        preview.updateNow(text: textView.string, documentURL: document?.fileURL)
    }

    // ⌃⌘S: the file tree. (In iA the list collapses with it; Draft's outline belongs to the writing area and has its own toggle.)
    @objc func toggleLibrary(_ sender: Any?) {
        let item = split.splitViewItems[0]
        NSAnimationContext.runAnimationGroup { _ in item.animator().isCollapsed = !item.isCollapsed }
        bars?.libraryToggled()
    }

    // ⇧⌘O: the outline on the left of the writing area.
    @objc func toggleOutline(_ sender: Any?) {
        let item = split.splitViewItems[1]
        NSAnimationContext.runAnimationGroup { _ in item.animator().isCollapsed = !item.isCollapsed }
    }

    // ⌘J: the assistant column on the right.
    @objc func toggleAssistant(_ sender: Any?) {
        guard let item = split.splitViewItems.last else { return }
        let show = item.isCollapsed
        NSAnimationContext.runAnimationGroup { _ in item.animator().isCollapsed = !show }
        if show {
            assistant.selectionChanged()
            assistant.focusInput()
        } else {
            window?.makeFirstResponder(textView)
        }
    }

    @objc func togglePreview(_ sender: Any?) {
        previewToolbar.previewVisible = !previewVisible
        previewVisible ? hidePreview() : showPreview()
    }

    // Cross-fade instead of a hard swap: the page is transparent until WebKit has rendered it,
    // so it fades in only once the text is on it (or after a short timeout).
    private static let fade: TimeInterval = 0.25
    private var previewTransition = 0

    private func showPreview() {
        previewVisible = true
        previewTransition += 1
        let token = previewTransition
        preview.inset = 76   // the page runs under the toolbar (fullSizeContentView)
        layoutPanes()
        let page = preview.view
        page.alphaValue = 0
        editorPane.isHidden = false
        refreshPreview()
        var done = false
        let reveal = { [weak self] in
            guard let self, !done, token == self.previewTransition else { return }
            done = true
            let full = self.preview.layout == .full
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fade
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                page.animator().alphaValue = 1
                if full { self.editorPane.animator().alphaValue = 0 }
            }, completionHandler: {
                guard token == self.previewTransition else { return }
                if full { self.editorPane.isHidden = true; self.editorPane.alphaValue = 1 }
            })
            self.window?.makeFirstResponder(full ? page : self.textView)
        }
        preview.whenRendered(reveal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reveal)
    }

    private func hidePreview() {
        previewVisible = false
        previewTransition += 1
        let token = previewTransition
        let page = preview.view
        let wasFull = editorPane.isHidden
        if wasFull { editorPane.alphaValue = 0; editorPane.isHidden = false }
        window?.makeFirstResponder(textView)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            page.animator().alphaValue = 0
            if wasFull { self.editorPane.animator().alphaValue = 1 }
        }, completionHandler: { [weak self] in
            guard let self, token == self.previewTransition else { return }
            page.alphaValue = 1
            self.layoutPanes()
        })
    }

    @objc func changePreviewWidthTo(_ sender: NSMenuItem) {
        preview.layout = PreviewViewController.Layout(rawValue: sender.tag) ?? .full
        if previewVisible {
            layoutPanes()
            if preview.layout == .full { editorPane.isHidden = true }
        } else {
            togglePreview(sender)
        }
    }

    // The preview is off the responder chain while the editor has focus; forward its actions.
    @objc func reloadPreview(_ sender: Any?) { if previewVisible { preview.reloadPreview(sender) } }
    @objc func changePreviewDisplayModeTo(_ sender: Any?) { preview.changePreviewDisplayModeTo(sender) }
    @objc func exportDocument(_ sender: Any?) { withRenderedPreview { $0.exportDocument(sender) } }
    @objc func printPreview(_ sender: Any?) { withRenderedPreview { $0.printPreview(sender) } }
    @objc func copyHTML(_ sender: Any?) { withRenderedPreview { $0.copyHTML(sender) } }

    private func withRenderedPreview(_ body: @escaping (PreviewViewController) -> Void) {
        _ = preview.view
        preview.updateNow(text: textView.string, documentURL: document?.fileURL)
        preview.whenRendered { [preview] in body(preview) }
    }

    func windowDidUpdate(_ notification: Notification) {
        if previewToolbar.focusEnabled != textView.focusMode { previewToolbar.focusEnabled = textView.focusMode }
        if previewToolbar.syntaxEnabled == textView.syntaxMask.isEmpty { previewToolbar.syntaxEnabled = !textView.syntaxMask.isEmpty }
        if previewToolbar.styleEnabled == textView.styleMask.isEmpty { previewToolbar.styleEnabled = !textView.styleMask.isEmpty }
    }

    private func buildSplit() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 230   // + ⌄ moves into the toolbar overflow (>>) below 220 (measured)
        sidebarItem.maximumThickness = 500
        // Part of the writing area: same paper, no divider line (PaletteSplitView), its own toggle.
        let outlineItem = NSSplitViewItem(viewController: outline)
        outlineItem.canCollapse = true
        outlineCollapsed = outlineItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.showOutlineButton.isHidden = !item.isCollapsed }
        }
        outlineItem.minimumThickness = 140
        outlineItem.maximumThickness = 400
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 300
        // Window resizes go to the editor.
        sidebarItem.holdingPriority = .init(261)
        outlineItem.holdingPriority = .init(260)
        editorItem.holdingPriority = .init(250)
        let assistantItem = NSSplitViewItem(viewController: assistant)
        assistantItem.canCollapse = true
        assistantItem.isCollapsed = true
        assistantItem.minimumThickness = 280
        assistantItem.maximumThickness = 640
        assistantItem.holdingPriority = .init(259)
        let splitView = PaletteSplitView()
        splitView.hiddenDividers = [1]
        split.splitView = splitView
        split.splitView.isVertical = true   // a fresh NSSplitView stacks top to bottom
        split.splitViewItems = [sidebarItem, outlineItem, editorItem, assistantItem]
        split.splitView.dividerStyle = .thin
    }

    // First run: the tree gets a width that fits file names.
    private func applyDefaultSplit() {
        needsDefaultSplit = false
        DispatchQueue.main.async {
            let splitView = self.split.splitView
            splitView.setPosition(LibraryStyle.sidebarWidth, ofDividerAt: 0)
            splitView.setPosition(LibraryStyle.sidebarWidth + LibraryStyle.outlineWidth, ofDividerAt: 1)
        }
    }

    // MARK: - Toolbar

    private enum Item {
        static let new = NSToolbarItem.Identifier("new")
        static let editorNav = NSToolbarItem.Identifier("editorNav")
        static let title = NSToolbarItem.Identifier("title")
        static let library = NSToolbarItem.Identifier("toggleLibrary")
        static let assistant = NSToolbarItem.Identifier("toggleAssistant")
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "Library")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Item.library, Item.new, .sidebarTrackingSeparator, Item.editorNav, .flexibleSpace, Item.title, .flexibleSpace, SyncStatusView.toolbarIdentifier]
            + PreviewToolbar.identifiers + [Item.assistant]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = previewToolbar.item(for: id) { return item }
        if id == SyncStatusView.toolbarIdentifier { return SyncStatusView.makeToolbarItem() }
        switch id {
        case Item.assistant:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            localize(item)
            item.action = #selector(toggleAssistant(_:))
            item.target = self
            item.isBordered = true
            return item
        case Item.library:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
            localize(item)
            item.action = #selector(toggleLibrary(_:))
            item.target = self
            return item
        case Item.editorNav:
            let control = segmented(["chevron.left", "chevron.right"], action: #selector(documentNavigate(_:)))
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control
            localize(item)
            editorNav = control
            updateNavButtons()
            return item
        case Item.new:
            let item = NSToolbarItem(itemIdentifier: id)
            let control = segmented(["plus", "chevron.down"], action: #selector(newClicked(_:)))
            item.view = control
            localize(item)
            return item
        case Item.title:
            let item = NSToolbarItem(itemIdentifier: id)
            titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.lineBreakMode = .byTruncatingMiddle
            titleLabel.delegate = self
            titleLabel.setAccessibilityIdentifier("title")
            localize(item)
            let icon = NSImageView(image: NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)!)
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
            let stack = PassThroughStack(views: [icon, titleLabel])
            stack.spacing = 4
            item.view = stack
            item.isBordered = false
            return item
        default:
            return nil
        }
    }

    // Labels and tooltips, set when an item is made and again when the language changes.
    private func localize(_ item: NSToolbarItem) {
        let control = item.view as? NSSegmentedControl
        switch item.itemIdentifier {
        case Item.assistant:
            item.label = L("Assistant")
            item.toolTip = L("Show or hide the AI assistant (⌘J)")
            item.image?.accessibilityDescription = L("Assistant")
        case Item.library:
            item.label = L("Library")
            item.toolTip = L("Show or hide the library (⌃⌘S)")
            item.image?.accessibilityDescription = L("Show Library")
        case Item.editorNav:
            item.label = L("Documents")
            control?.setToolTip(L("Back to the previous document"), forSegment: 0)
            control?.setToolTip(L("Forward to the next document"), forSegment: 1)
        case Item.new:
            item.label = L("New")
            control?.setToolTip(L("New document (⌘N)"), forSegment: 0)
            control?.setToolTip(L("New file or folder"), forSegment: 1)
        case Item.title:
            titleLabel.toolTip = L("Click to rename")
        case SyncStatusView.toolbarIdentifier:
            item.label = L("Sync")
        default: break
        }
    }

    // A two-segment capsule; iA's are 72 pt wide.
    private func segmented(_ symbols: [String], action: Selector) -> NSSegmentedControl {
        let control = NSSegmentedControl(images: symbols.map { NSImage(systemSymbolName: $0, accessibilityDescription: nil)! },
                                         trackingMode: .momentary, target: self, action: action)
        for i in 0..<2 { control.setWidth(28, forSegment: i) }
        return control
    }

    // MARK: - Navigation

    private func updateNavButtons() {
        editorNav?.setEnabled(documentIndex > 0, forSegment: 0)
        editorNav?.setEnabled(documentIndex < documentHistory.count - 1, forSegment: 1)
    }

    @objc private func documentNavigate(_ sender: NSSegmentedControl) {
        let target = documentIndex + (sender.selectedSegment == 0 ? -1 : 1)
        guard documentHistory.indices.contains(target) else { return }
        documentIndex = target
        open(documentHistory[target], recordHistory: false)
    }

    @objc private func newClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { newDocument(); return }
        let menu = NSMenu()
        menu.addItem(MenuClosureItem(title: L("New File")) { [weak self] in self?.newDocument() })
        menu.addItem(MenuClosureItem(title: L("New Folder")) { [weak self] in self?.newFolder() })
        if let event = NSApp.currentEvent, let view = event.window?.contentView {
            menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        }
    }

    private func newDocument() {
        NSDocumentController.shared.newDocument(nil)
    }

    private func newFolder() {
        let parent = newDocumentFolder
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        var name = "Untitled Folder", n = 2
        while existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { name = "Untitled Folder \(n)"; n += 1 }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        Library.shared.refresh([folder])
    }

    func open(_ url: URL, recordHistory: Bool = true, then: (() -> Void)? = nil) {
        if recordHistory {
            documentHistory = Array(documentHistory.prefix(documentIndex + 1)) + [url]
            documentIndex = documentHistory.count - 1
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) } else { then?() }
        }
        updateNavButtons()
    }

    // MARK: - Documents

    // Attach `doc` to the editor, detaching whatever was shown.
    func show(_ doc: TextDocument) {
        if let current = document as? TextDocument, current !== doc {
            commit(into: current)
            textView.breakUndoCoalescing()
            current.removeWindowController(self)
            current.lastShown = Date()
            // A never-written draft is written when it's left, so it has a row in the tree; an empty one goes away.
            if current.isUnwritten {
                if current.text.isEmpty { current.close() } else {
                    current.saveDraft { _ in if let url = current.fileURL { Library.shared.refresh([url]) } }
                }
            } else if current.isDocumentEdited {
                current.autosave(withImplicitCancellability: false) { _ in }
            }
        }
        if document !== doc {
            doc.addWindowController(self)
            load(doc)
        }
        doc.lastShown = Date()
        if let url = doc.fileURL { UserDefaults.standard.set(url.path, forKey: Self.lastDocumentKey) }
        (NSDocumentController.shared as? DocumentController)?.trimInactiveDocuments()
        sidebar.show(file: doc.fileURL)
        if let url = doc.fileURL, documentHistory.last != url, documentIndex == documentHistory.count - 1 {
            documentHistory.append(url)
            documentIndex = documentHistory.count - 1
        }
        updateNavButtons()
        updateTitle()
        showWindow(nil)
        if needsDefaultSplit { applyDefaultSplit() }
        window?.makeFirstResponder(textView)
    }

    private func load(_ doc: TextDocument) {
        loading = true
        defer { loading = false }
        let undo = textView.undoManager
        undo?.disableUndoRegistration()
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: all, replacementString: doc.text) {
            textView.textStorage?.replaceCharacters(in: all, with: doc.text)
            textView.didChangeText()
        }
        undo?.enableUndoRegistration()
        let length = (doc.text as NSString).length
        var range = doc.selectedRange ?? NSRange(location: length, length: 0)
        if NSMaxRange(range) > length { range = NSRange(location: length, length: 0) }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        formatBar.update(block: block(), text: doc.text)
        outline.fileURL = doc.fileURL
        outline.caretMoved(to: range.location)
        outline.update(text: doc.text)
        refreshPreview()
    }

    // Push the editor's text and selection into the document (before saving or detaching).
    func commit(into doc: TextDocument) {
        guard doc.windowControllers.contains(self) else { return }
        doc.text = textView.string
        doc.selectedRange = textView.selectedRange()
    }

    func reload(_ doc: TextDocument) {
        guard document === doc else { return }
        load(doc)
        updateTitle()
    }

    // A draft with no text yet is saved as "Untitled", but shows it in the UI language.
    private func shownName(_ doc: TextDocument) -> String {
        if let url = doc.fileURL { return url.lastPathComponent }
        let name = doc.derivedName.name
        return name == DocumentName.fallback ? L(name) : name
    }

    private func updateTitle() {
        guard let doc = document as? TextDocument else { return }
        let name = shownName(doc)
        if titleLabel.currentEditor() == nil { titleLabel.stringValue = name }
        window?.title = name
    }

    // MARK: - Closing and renaming

    // ⌘W: close the document, keep the window, show a fresh draft (iA's _closeDocument:).
    @objc func closeDocument(_ sender: Any?) {
        guard let doc = document as? TextDocument else { return }
        commit(into: doc)
        textView.breakUndoCoalescing()
        doc.removeWindowController(self)
        NSDocumentController.shared.newDocument(nil)
        (NSDocumentController.shared as? DocumentController)?.close(doc)
    }

    // Right click → Move to Trash. Open copies of the file (or of files inside a trashed folder) close unsaved;
    // the window moves on to a fresh draft if it was showing one of them.
    func moveToTrash(_ url: URL) {
        let inside = { (doc: NSDocument) in doc.fileURL.map { $0 == url || $0.path.hasPrefix(url.path + "/") } ?? false }
        for case let doc as TextDocument in NSDocumentController.shared.documents where inside(doc) {
            if doc === document { doc.removeWindowController(self); NSDocumentController.shared.newDocument(nil) }
            doc.close()
        }
        // Like Finder: no confirmation; the file can be put back from the Trash.
        NSWorkspace.shared.recycle([url]) { _, error in
            if let error { NSApp.presentError(error) }
            Library.shared.refresh([url])
        }
    }

    // Dragged onto a sidebar folder. Coordinated, so open documents follow their files. Name clashes get " 2", " 3".
    func move(_ urls: [URL], into folder: URL) {
        var moved: [(URL, URL)] = []
        for url in urls {
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let name = url.lastPathComponent, ext = (name as NSString).pathExtension
            var unique = name
            if url.hasDirectoryPath || ext.isEmpty {
                var n = 2
                while existing.contains(where: { $0.caseInsensitiveCompare(unique) == .orderedSame }) { unique = "\(name) \(n)"; n += 1 }
            } else {
                unique = DocumentName.uniqueFileName(stem: (name as NSString).deletingPathExtension, ext: ext, existing: existing)
            }
            let target = folder.appendingPathComponent(unique, isDirectory: url.hasDirectoryPath)
            var coordError: NSError?, error: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &coordError) { from, to in
                do {
                    try FileManager.default.moveItem(at: from, to: to)
                    NSFileCoordinator().item(at: from, didMoveTo: to)
                } catch let e { error = e }
            }
            if let e = coordError ?? error { NSApp.presentError(e); continue }
            moved.append((url, target))
        }
        guard !moved.isEmpty else { return }
        let remap = { (old: URL) -> URL in
            for (from, to) in moved {
                if Library.key(old) == Library.key(from) { return to }
                if Library.key(old).hasPrefix(Library.key(from) + "/") {
                    return URL(fileURLWithPath: Library.key(to) + Library.key(old).dropFirst(Library.key(from).count), isDirectory: old.hasDirectoryPath)
                }
            }
            return old
        }
        documentHistory = documentHistory.map(remap)
        for (from, to) in moved { sidebar.folderMoved(from: from, to: to); SidebarViewController.favoritesMoved(from: from, to: to) }
        sidebar.show(file: document?.fileURL.map(remap))  // the document learns its new URL asynchronously
        Library.shared.refresh(moved.flatMap { [$0.0, $0.1] })
    }

    // Library → Rename… and a click on the title both edit the title in place.
    @objc func renameCurrentDocument(_ sender: Any?) {
        guard document != nil else { return }
        window?.makeFirstResponder(titleLabel)
        titleLabel.currentEditor()?.selectedRange = NSRange(location: 0, length: ((titleLabel.stringValue as NSString).deletingPathExtension as NSString).length)
    }

    // AppKit's own File → Rename… lands here too, instead of NSDocument's title-bar popover (the title bar is hidden).
    @objc func renameDocument(_ sender: Any?) { renameCurrentDocument(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeDocument(_:)), #selector(renameCurrentDocument(_:)), #selector(renameDocument(_:)): return document != nil
        case #selector(changeTitlebarVisibility(_:)):
            item.state = BarVisibility.titlebarSetting == item.tag ? .on : .off
            return true
        case #selector(changeToolbarVisibility(_:)):
            item.state = BarVisibility.bottomBarSetting == item.tag ? .on : .off
            return true
        case #selector(toggleBarFade(_:)):
            item.state = BarVisibility.titlebarSetting == 0 ? .on : .off
            return true
        default: return true
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleLabel, let doc = document as? TextDocument else { return }
        let input = titleLabel.stringValue
        let unchanged = input == shownName(doc)
        updateTitle()
        window?.makeFirstResponder(textView)
        if !unchanged { rename(doc, to: input) }
    }

    // The name is cleaned up as in docs/storage.md §3.4; a never-written draft is written first.
    func rename(_ doc: TextDocument, to input: String) {
        if doc.isUnwritten {
            commit(into: doc)
            doc.saveDraft { [weak self] ok in
                guard ok, doc.fileURL != nil else { return }
                self?.rename(doc, to: input)
            }
            return
        }
        guard let old = doc.fileURL, let file = DocumentName.renamedFileName(input, current: old.lastPathComponent) else { return }
        let folder = old.deletingLastPathComponent()
        let existing = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != old.lastPathComponent }
        let ext = (file as NSString).pathExtension
        let unique = DocumentName.uniqueFileName(stem: (file as NSString).deletingPathExtension, ext: ext, existing: existing)
        guard unique != old.lastPathComponent else { return }
        let target = folder.appendingPathComponent(unique)
        SidebarViewController.renamesInFlight += 1
        doc.move(to: target) { [weak self] error in
            DispatchQueue.main.async {
                SidebarViewController.renamesInFlight -= 1
                if let error { NSApp.presentError(error); return }
                SidebarViewController.favoritesMoved(from: old, to: target)
                guard let self else { return }
                self.documentHistory = self.documentHistory.map { $0 == old ? target : $0 }
                self.updateTitle()
                self.sidebar.show(file: doc.fileURL)
                Library.shared.refresh([old, target])
            }
        }
    }

    // MARK: - Text view delegate

    func textDidChange(_ notification: Notification) {
        guard !loading, let doc = document as? TextDocument else { return }
        // Edits that bypass the undo manager (accessibility, services) still have to mark the document.
        if !doc.isDocumentEdited { doc.updateChangeCount(.changeDone) }
        if previewVisible { preview.update(text: textView.string, documentURL: doc.fileURL) }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateCount), object: nil)
        perform(#selector(updateCount), with: nil, afterDelay: 0.1)
        if doc.isUnwritten {
            updateTitle()
            // The file is created once the name is final (Return after the first line, or > 64 characters).
            if !textView.hasMarkedText() && doc.derivedName.isFinal {
                doc.saveDraft { [weak self] _ in
                    self?.updateTitle()
                    self?.sidebar.show(file: doc.fileURL)
                    if let url = doc.fileURL { Library.shared.refresh([url]) }
                }
            }
        }
    }

    @objc private func updateCount() {
        formatBar.updateCount(textView.string)
        outline.fileURL = document?.fileURL   // a draft gets one once it's written
        outline.update(text: textView.string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !loading else { return }
        outline.caretMoved(to: textView.selectedRange().location)
        formatBar.update(block: block(), text: textView.string)
        if split.splitViewItems.last?.isCollapsed == false { assistant.selectionChanged() }
    }

    // MARK: - Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (document as? NSDocument)?.undoManager
    }

    // Loaded documents share this window's text view for undo, so they go with it (autosaving on the way out).
    func windowWillClose(_ notification: Notification) {
        if LibraryWindowController.existing === self { LibraryWindowController.existing = nil }
        guard let controller = NSDocumentController.shared as? DocumentController, !controller.closingAll else { return }
        for doc in controller.documents.compactMap({ $0 as? TextDocument }) where doc.windowControllers.isEmpty {
            controller.close(doc)
        }
    }
}

extension Library {
    static func excerpt(of text: String) -> String {
        var excerpt = ""
        text.enumerateLines { line, stop in
            let stripped = DocumentName.stripMarkdown(line).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.allSatisfy({ "-*_= ".contains($0) }) { return }
            excerpt += excerpt.isEmpty ? stripped : " " + stripped
            if excerpt.count > 200 { stop = true }
        }
        return excerpt
    }
}

// Takes clicks only on its subviews, so the rest of the toolbar item drags the window.
private final class PassThroughStack: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// The document name in the toolbar: looks like a label, edits in place when clicked (rename).
final class TitleField: NSTextField {
    // Room around the text for the hover/editing fill.
    final class PaddedCell: NSTextFieldCell {
        static let padding: CGFloat = 5
        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            super.drawingRect(forBounds: rect.insetBy(dx: Self.padding, dy: 0))
        }
        override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
            super.select(withFrame: rect.insetBy(dx: Self.padding, dy: 0), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        }
        override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: rect.insetBy(dx: Self.padding, dy: 0), in: controlView, editor: textObj, delegate: delegate, event: event)
        }
        override func cellSize(forBounds rect: NSRect) -> NSSize {
            var size = super.cellSize(forBounds: rect)
            size.width += 2 * Self.padding
            return size
        }
    }
    override class var cellClass: AnyClass? { get { PaddedCell.self } set {} }

    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
        isBordered = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        focusRingType = .none
        cell?.isScrollable = true
        cell?.usesSingleLineMode = true
    }
    // Escape puts the old name back.
    override func cancelOperation(_ sender: Any?) {
        abortEditing()
        window?.makeFirstResponder(nil)
    }

    // A faint rounded fill on hover, a stronger one while editing: shows the name can be edited.
    private var hovering = false { didSet { updateFill() } }
    private var editing = false { didSet { updateFill(); window?.invalidateCursorRects(for: self) } }
    override var stringValue: String { didSet { window?.invalidateCursorRects(for: self) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovering = nameRect.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // The I-beam only over the name: the field is stretched across the toolbar, which should stay draggable.
    override func resetCursorRects() {
        addCursorRect(editing ? bounds : nameRect, cursor: .iBeam)
    }

    // Clicks beside the name fall through to the toolbar instead of starting a rename.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !editing, let superview else { return super.hitTest(point) }
        return nameRect.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    // Where the name is drawn, plus the padding.
    private var nameRect: NSRect {
        let text = (currentEditor()?.string ?? stringValue) as NSString
        let width = min(text.size(withAttributes: [.font: font ?? .systemFont(ofSize: 14)]).width + 2 * PaddedCell.padding + 4, bounds.width)
        let x: CGFloat
        switch alignment {
        case .center: x = (bounds.width - width) / 2
        case .right: x = bounds.width - width
        default: x = userInterfaceLayoutDirection == .rightToLeft ? bounds.width - width : 0
        }
        return NSRect(x: x, y: 0, width: width, height: bounds.height)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { editing = true }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        editing = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    // The fill hugs the name, not the whole (stretched) field.
    private let fill = CALayer()

    private func updateFill() {
        wantsLayer = true
        if fill.superlayer == nil {
            fill.cornerRadius = 5
            layer?.insertSublayer(fill, at: 0)
        }
        let alpha: CGFloat = editing ? 0.12 : hovering ? 0.07 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = nameRect
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.backgroundColor = (Palette.current?.text ?? .labelColor).withAlphaComponent(alpha).cgColor
        }
        CATransaction.commit()
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        updateFill()
    }
}

// The editor column's page colour (the palette's, or iA's), behind the text and the outline button.
// Behind the transparent title bar: frosted glass under the page colour, fading out at its lower edge, so text
// scrolled up under the toolbar blurs instead of running into its buttons. Fades with the title bar (BarVisibility).
private final class TitlebarBand: NSView {
    static let fade: CGFloat = 12
    private let blur = NSVisualEffectView()
    private let tint = NSView()
    private let mask = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blur.material = .headerView
        blur.blendingMode = .withinWindow
        blur.state = .active
        tint.wantsLayer = true
        for v in [blur, tint] { v.frame = bounds; v.autoresizingMask = [.width, .height]; addSubview(v) }
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        layer?.mask = mask
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint.layer?.backgroundColor = Theme.background.withAlphaComponent(0.75).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        // Layer y runs up from the bottom edge: clear at the bottom, opaque from `fade` up.
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: min(Self.fade / max(bounds.height, 1), 1))
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PageView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        dirtyRect.fill()
    }
}
