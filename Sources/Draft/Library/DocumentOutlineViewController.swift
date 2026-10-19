import AppKit

// Floating over the page's left margin: the open document's headings (# … ######) as small cards on the editor's background, indented by
// level, each with up to two lines of the text under it. A click puts the caret on the heading; dragging a card moves
// its section (down to the next heading of the same or a higher level) to where it's dropped.
final class DocumentOutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Heading: Equatable {
        let level: Int
        let title: String
        let location: Int
        let excerpt: String
    }

    var onJump: ((Int) -> Void)?
    // The open document's file: section tags are kept per file and heading title (SectionTags); none for a draft.
    var fileURL: URL? { didSet { if fileURL != oldValue { headings = [] } } }   // another file: rebuild the cards
    // A section drag: replace `range` with `text` (one undo step) and put the caret at `caret`.
    var onMove: ((_ range: NSRange, _ text: String, _ caret: Int) -> Void)?
    private var headings: [Heading] = []
    private var text = ""
    private var caret = 0
    private var current: Int?   // the section the caret is in
    private var dragged = IndexSet()   // the dragged section's cards, dimmed while it moves
    private static let dragType = NSPasteboard.PasteboardType("app.draft.outline-section")
    private let table = OutlineTable()
    private weak var header: OutlineHeaderView?
    private let empty = NSTextField(labelWithString: "")
    // The editor's paper: its line height and where its pattern starts (window coordinates), so the outline's pattern
    // continues the editor's and moves with it.
    var paper: () -> (pitch: CGFloat, anchor: NSPoint) = { (28, .zero) }
    var onCollapse: (() -> Void)?
    private static let pattern = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.*?)[ \t#]*$"#, options: [.anchorsMatchLines])
    private static let titleFont = NSFont.systemFont(ofSize: 13)
    private static let excerptFont = NSFont.systemFont(ofSize: 11.5)
    // Markdown taken out of excerpts: links keep their text, list/quote markers and emphasis characters go.
    private static let link = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)
    private static let marks = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+][ \t]+\[[ xX]\][ \t]+|[-*+>][ \t]+|\d+\.[ \t]+)|[*_=~`]+"#,
                                                        options: [.anchorsMatchLines])

    override func loadView() {
        let root = EditorBackgroundView()
        root.clipsToBounds = true   // it floats over the editor: its page fill would otherwise cover the text
        root.paper = { [unowned self] in self.paper() }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = ThinScroller()
        scroll.autohidesScrollers = true
        // Like the sidebar: the scroll view runs under the title bar (which would otherwise draw white there), the
        // content starts below it and the header.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 50 + OutlineHeaderView.height, left: 0, bottom: 0, right: 0)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none   // the cards show the caret's section and the hover instead
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.rowHeight = 34
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .none   // OutlineTable draws its own line
        scroll.documentView = table
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = LibraryStyle.paletteSecondaryText
        let header = OutlineHeaderView(padding: Self.padding)
        header.onCollapse = { [unowned self] in self.onCollapse?() }
        self.header = header
        for v in [scroll, header, empty] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 50),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: OutlineHeaderView.height),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        applyLanguage()
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in self?.applyLanguage() }
        NotificationCenter.default.addObserver(forName: Settings.paperOpacityDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.view.needsDisplay = true
            self?.header?.needsDisplay = true
        }
        // Narrower or wider column: excerpts wrap differently.
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: table, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.headings.count))
        }
    }

    // Headings outside code blocks.
    func update(text: String) {
        let ns = text as NSString
        let code = Markdown.codeBlocks(in: text)
        let found = Self.pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { m in !code.contains(where: { NSLocationInRange(m.range.location, $0) }) }
        let new = found.enumerated().map { i, m in
            let end = i + 1 < found.count ? found[i + 1].range.location : ns.length
            let body = NSRange(location: NSMaxRange(m.range), length: end - NSMaxRange(m.range))
            return Heading(level: m.range(at: 1).length, title: ns.substring(with: m.range(at: 2)), location: m.range.location,
                           excerpt: Self.excerpt(ns, body, code: code))
        }
        self.text = text
        guard new != headings else { return }
        // A heading renamed in place (same position, nothing else changed) keeps its tag.
        if let fileURL, new.count == headings.count {
            let renamed = zip(headings, new).filter { $0.title != $1.title }
            if renamed.count == 1, let (old, now) = renamed.first, let status = SectionTags.status(fileURL, old.title),
               SectionTags.status(fileURL, now.title) == nil {
                SectionTags.set(fileURL, now.title, status)
                SectionTags.set(fileURL, old.title, nil)
            }
        }
        headings = new
        _ = view
        current = headings.lastIndex { $0.location <= caret }
        table.reloadData()
        empty.isHidden = !headings.isEmpty
    }

    // The caret moved: mark its section's card and keep it in view.
    func caretMoved(to location: Int) {
        caret = location
        let now = headings.lastIndex { $0.location <= location }
        guard now != current else { return }
        current = now
        refreshCells()
        if let now, dragged.isEmpty { table.scrollRowToVisible(now) }
    }

    private func refreshCells() {
        table.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? OutlineCell else { return }
            cell.isCurrent = row == current
            cell.isDragged = dragged.contains(row)
        }
    }

    // The section's prose on one line: code blocks, tables and footnote definitions left out, Markdown stripped.
    private static func excerpt(_ ns: NSString, _ range: NSRange, code: [NSRange]) -> String {
        var lines: [String] = []
        var length = 0
        ns.enumerateSubstrings(in: range, options: [.byLines]) { line, lineRange, _, stop in
            guard let line, !code.contains(where: { NSLocationInRange(lineRange.location, $0) }) else { return }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("|"), !t.hasPrefix("[^"), !t.hasPrefix("---") else { return }
            let plain = marks.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
            lines.append(plain)
            length += plain.count
            if length > 200 { stop.pointee = true }
        }
        let joined = lines.joined(separator: " ")
        return link.stringByReplacingMatches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length), withTemplate: "$1")
    }

    // The editor scrolled or relaid out: the pattern follows.
    func paperMoved() {
        guard isViewLoaded else { return }
        view.needsDisplay = true
        header?.needsDisplay = true
    }

    // Palette changed: refill and recolour.
    func applyPalette() {
        view.needsDisplay = true
        header?.needsDisplay = true
        table.reloadData()
    }

    // Status names are read as the cards are made, so new cards pick up the language.
    private func applyLanguage() {
        empty.stringValue = L("No headings")
        header?.applyLanguage()
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }

    // The card: padding, the title line, then the excerpt (at most two lines).
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let h = headings[row]
        guard !h.excerpt.isEmpty else { return 34 }
        let width = max(tableView.bounds.width - indent(h) - 8 - 2 * Self.padding, 40)
        let line = ceil(NSLayoutManager().defaultLineHeight(for: Self.excerptFont))
        let text = (h.excerpt as NSString).boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin],
                                                         attributes: [.font: Self.excerptFont])
        return 34 + min(ceil(text.height), line * 2) + 4
    }

    private static let padding: CGFloat = 10
    private func indent(_ h: Heading) -> CGFloat { 8 + CGFloat(h.level - 1) * 10 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let h = headings[row]
        let cell = OutlineCell(level: h.level, indent: indent(h), padding: Self.padding, titleFont: Self.titleFont, excerptFont: Self.excerptFont)
        cell.title.stringValue = h.title.isEmpty ? "#" : h.title
        cell.excerpt.stringValue = h.excerpt
        cell.excerpt.isHidden = h.excerpt.isEmpty
        cell.status = fileURL.flatMap { SectionTags.status($0, h.title) }
        cell.isCurrent = row == current
        cell.isDragged = dragged.contains(row)
        cell.tagsEnabled = fileURL != nil
        cell.onToggle = { [weak self, weak cell] status in
            guard let self, let fileURL = self.fileURL, let cell else { return }
            let new = cell.status == status ? nil : status
            SectionTags.set(fileURL, h.title, new)
            cell.status = new
        }
        return cell
    }

    // MARK: - Moving sections

    private func section(_ row: Int) -> NSRange {
        let start = headings[row].location
        let end = headings[(row + 1)...].first { $0.level <= headings[row].level }?.location ?? (text as NSString).length
        return NSRange(location: start, length: end - start)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        guard let row = rowIndexes.first else { return }
        let range = section(row)
        dragged = IndexSet(headings.indices.filter { NSLocationInRange(headings[$0].location, range) })
        table.dropIndent = indent(headings[row])
        table.dragging = true
        refreshCells()
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        dragged = []
        table.dragging = false
        table.dropRow = nil
        refreshCells()
    }

    // Over a card: before it in its top half, after it in the bottom half. Never inside the dragged section itself.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let source = draggedRow(info) else { return [] }
        var row = row
        if operation == .on {
            let point = tableView.convert(info.draggingLocation, from: nil)
            if point.y > tableView.rect(ofRow: row).midY { row += 1 }
            tableView.setDropRow(row, dropOperation: .above)
        }
        let target = row < headings.count ? headings[row].location : (text as NSString).length
        let range = section(source)
        let valid = !(target >= range.location && target <= NSMaxRange(range))
        table.dropRow = valid ? row : nil
        return valid ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let source = draggedRow(info) else { return false }
        let target = row < headings.count ? headings[row].location : (text as NSString).length
        guard let move = Self.move(section(source), to: target, in: text) else { return false }
        onMove?(move.range, move.text, move.caret)
        return true
    }

    // Moving `range` so it starts at `target`: the span to replace, its new text, and where the moved section begins.
    static func move(_ range: NSRange, to target: Int, in text: String) -> (range: NSRange, text: String, caret: Int)? {
        let ns = text as NSString
        guard target < range.location || target > NSMaxRange(range) else { return nil }
        // Each piece ends with a blank line, as sections usually do; the last section may have none.
        func blankLineAfter(_ s: String) -> String { s.hasSuffix("\n\n") ? s : s.hasSuffix("\n") ? s + "\n" : s + "\n\n" }
        let block = blankLineAfter(ns.substring(with: range))
        if target < range.location {
            let between = ns.substring(with: NSRange(location: target, length: range.location - target))
            return (NSRange(location: target, length: NSMaxRange(range) - target), block + between, target)
        }
        let between = blankLineAfter(ns.substring(with: NSRange(location: NSMaxRange(range), length: target - NSMaxRange(range))))
        return (NSRange(location: range.location, length: target - range.location), between + block, range.location + (between as NSString).length)
    }

    private func draggedRow(_ info: NSDraggingInfo) -> Int? {
        guard let row = info.draggingPasteboard.string(forType: Self.dragType).flatMap(Int.init), headings.indices.contains(row) else { return nil }
        return row
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard headings.indices.contains(row) else { return }
        onJump?(headings[row].location)
    }
}

// Draws where a dragged section will land: a line in the gap above `dropRow`, at the section's indent.
private final class OutlineTable: NSTableView {
    var dragging = false
    var dropIndent: CGFloat = 8
    var dropRow: Int? { didSet { if dropRow != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let dropRow, numberOfRows > 0 else { return }
        let y = dropRow < numberOfRows ? rect(ofRow: dropRow).minY - intercellSpacing.height / 2
                                       : rect(ofRow: numberOfRows - 1).maxY + intercellSpacing.height / 2
        let line = NSBezierPath(roundedRect: NSRect(x: dropIndent, y: y - 1.5, width: bounds.width - dropIndent - 8, height: 3),
                                xRadius: 1.5, yRadius: 1.5)
        Theme.caret.setFill()
        line.fill()
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        dropRow = nil
    }
}

// The editor's background colour (the palette's, or iA's), so the outline reads as part of the page.
// With the editor's paper pattern (Settings → Paper) at the editor's line height; the notebook margin is left out.
private final class EditorBackgroundView: NSView {
    var paper: () -> (pitch: CGFloat, anchor: NSPoint) = { (28, .zero) }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let (pitch, anchor) = paper()
        Self.drawPaper(in: dirtyRect, of: self, pitch: pitch, anchor: anchor)
    }

    // It floats over the editor, so it picks the cursor itself (the text's I-beam lies underneath): the hand on cards
    // and buttons, the arrow elsewhere.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
    }
    override func cursorUpdate(with event: NSEvent) { setCursor(event) }
    override func mouseMoved(with event: NSEvent) { setCursor(event) }
    private func setCursor(_ event: NSEvent) {
        var view = superview.flatMap { hitTest($0.convert(event.locationInWindow, from: nil)) }
        while let v = view, v !== self, !(v is NSButton || v is OutlineCard || v is EmojiButton) { view = v.superview }
        (view == nil || view === self ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    // Draws background and pattern in `view` (flipped), the pattern starting at `anchor` (window coordinates).
    static func drawPaper(in rect: NSRect, of view: NSView, pitch: CGFloat, anchor: NSPoint) {
        Theme.background.setFill()
        rect.fill()
        let paper = Settings.paper
        guard paper != .none else { return }
        let palette = Palette.current
        let opacity = CGFloat(Settings.paperOpacity)
        let line = (palette?.paperLine ?? Theme.syntax).withAlphaComponent((palette == nil ? 0.35 : 1) * opacity)
        let origin = view.convert(anchor, from: nil)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            let shift = NSAffineTransform()
            shift.translateX(by: origin.x, yBy: origin.y)
            shift.concat()
            paper.draw(in: rect.offsetBy(dx: -origin.x, dy: -origin.y), top: 0, pitch: pitch, left: -.greatestFiniteMagnitude,
                       line: line, margin: .clear)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

// "章節" above the cards, like the sidebar's section titles, with the button that folds the outline away. Opaque (the
// page behind it, pattern lined up), as cards scroll under it.
private final class OutlineHeaderView: NSView {
    static let height: CGFloat = 30
    var onCollapse: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private lazy var collapse = NSButton(image: NSImage(systemSymbolName: "chevron.left.2", accessibilityDescription: "Hide Outline")!,
                                         target: self, action: #selector(collapseClicked))
    override var isFlipped: Bool { true }

    init(padding: CGFloat) {
        super.init(frame: .zero)
        clipsToBounds = true   // its page fill would otherwise cover the cards below
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = LibraryStyle.paletteSecondaryText
        collapse.isBordered = false
        collapse.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        collapse.contentTintColor = LibraryStyle.paletteSecondaryText
        applyLanguage()
        for v in [label, collapse] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8 + padding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -3),
            collapse.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8 - padding),
            collapse.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    func applyLanguage() {
        label.stringValue = L("Outline")
        collapse.toolTip = L("Hide Outline (⇧⌘O)")
        collapse.setAccessibilityLabel(L("Hide Outline"))
    }

    @objc private func collapseClicked() { onCollapse?() }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let page = superview as? EditorBackgroundView else { return }
        let (pitch, anchor) = page.paper()
        EditorBackgroundView.drawPaper(in: dirtyRect, of: self, pitch: pitch, anchor: anchor)
    }

}

// A section's writing status, set from its card in the outline (Draft addition).
enum SectionStatus: String, CaseIterable {
    case idea, draft, revise, done, cut

    var title: String { L(["Status|Idea", "Status|Draft", "Status|Revise", "Status|Done", "Status|Cut"][Self.allCases.firstIndex(of: self)!]) }
    var emoji: String { ["💡", "✏️", "🔁", "✅", "✂️"][Self.allCases.firstIndex(of: self)!] }
    var color: NSColor { [.systemYellow, .systemBlue, .systemOrange, .systemGreen, .systemRed][Self.allCases.firstIndex(of: self)!] }
}

// Tags live in Application Support/Draft/SectionTags.json, by file path and heading title, so the text stays as written.
enum SectionTags {
    private static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Draft/SectionTags.json")
    private static var all: [String: [String: String]] = {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
    }()

    static func status(_ url: URL, _ title: String) -> SectionStatus? {
        all[url.standardizedFileURL.path]?[title].flatMap(SectionStatus.init(rawValue:))
    }

    static func set(_ url: URL, _ title: String, _ status: SectionStatus?) {
        let key = url.standardizedFileURL.path
        all[key, default: [:]][title] = status?.rawValue
        if all[key]?.isEmpty == true { all[key] = nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
    }
}

// One heading's card: title, status label, excerpt; on hover the five status buttons replace the label.
private final class OutlineCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let excerpt = NSTextField(wrappingLabelWithString: "")
    var onToggle: ((SectionStatus) -> Void)?
    var tagsEnabled = true
    var status: SectionStatus? { didSet { update() } }
    // The caret's section: its excerpt in the text colour, so it stays readable on the tinted card.
    var isCurrent = false {
        didSet {
            card.isCurrent = isCurrent
            excerpt.textColor = isCurrent ? LibraryStyle.paletteText.withAlphaComponent(0.7) : LibraryStyle.paletteSecondaryText
        }
    }
    var isDragged = false { didSet { alphaValue = isDragged ? 0.35 : 1 } }
    private let card = OutlineCard()
    private let pill = StatusPill()
    private let hint = HintLabel()   // the hovered emoji's name, right under it
    private var hintX: NSLayoutConstraint?
    private let buttons = NSStackView()

    init(level: Int, indent: CGFloat, padding: CGFloat, titleFont: NSFont, excerptFont: NSFont) {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: titleFont.pointSize, weight: level == 1 ? .semibold : .regular)
        title.textColor = level <= 2 ? LibraryStyle.paletteText : LibraryStyle.paletteSecondaryText
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        excerpt.font = excerptFont
        excerpt.isSelectable = false   // a wrapping label is selectable: a click there would select text instead of jumping
        excerpt.textColor = LibraryStyle.paletteSecondaryText
        excerpt.maximumNumberOfLines = 2
        excerpt.cell?.truncatesLastVisibleLine = true
        excerpt.lineBreakMode = .byWordWrapping
        for s in SectionStatus.allCases {
            let b = EmojiButton(s)
            b.onPress = { [weak self] in self?.onToggle?(s) }
            b.onHover = { [weak self, weak b] inside in
                guard let self, let b else { return }
                self.hint.isHidden = !inside
                guard inside else { return }
                self.hint.text = s.title
                self.hintX?.isActive = false
                self.hintX = self.hint.centerXAnchor.constraint(equalTo: b.centerXAnchor)
                self.hintX?.priority = .defaultHigh   // kept inside the card at the right edge
                self.hintX?.isActive = true
            }
            buttons.addArrangedSubview(b)
        }
        hint.isHidden = true
        buttons.spacing = 3
        buttons.isHidden = true
        card.onHover = { [weak self] in self?.hovering = $0 }
        for v in [card, title, excerpt, pill, buttons, hint] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(card)
        [title, excerpt, pill, buttons, hint].forEach(card.addSubview)
        textField = title
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: padding),
            title.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: card.topAnchor, constant: 17),
            pill.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            pill.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            buttons.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            excerpt.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            excerpt.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -padding),
            excerpt.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            hint.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 4),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var hovering = false { didSet { update() } }

    // Only the card follows the pointer, without the hover buttons.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        card.hovering = false
        card.displayIfNeeded()
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return super.draggingImageComponents }
        card.cacheDisplay(in: card.bounds, to: rep)
        let image = NSImage(size: card.bounds.size)
        image.addRepresentation(rep)
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = card.frame
        return [component]
    }

    private func update() {
        let showButtons = hovering && tagsEnabled
        buttons.isHidden = !showButtons
        pill.isHidden = showButtons || status == nil
        pill.status = status
        // The chosen one at full strength, the others a little lighter.
        for case let b as EmojiButton in buttons.arrangedSubviews {
            b.alphaValue = status == nil || b.status == status ? 1 : 0.55
        }
    }

}

// A status button: a small emoji that grows under the pointer (drawn large, shown scaled down, so it stays sharp).
private final class EmojiButton: NSView {
    let status: SectionStatus
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private let glyph = CALayer()
    private static let drawn: CGFloat = 26
    private static let rest: CGFloat = 15 / drawn

    init(_ status: SectionStatus) {
        self.status = status
        super.init(frame: NSRect(x: 0, y: 0, width: 19, height: 19))
        wantsLayer = true
        layer?.masksToBounds = false
        let size = NSSize(width: Self.drawn, height: Self.drawn)
        glyph.contents = NSImage(size: size, flipped: false) { rect in
            let text = NSAttributedString(string: status.emoji, attributes: [.font: NSFont.systemFont(ofSize: Self.drawn * 0.8)])
            let s = text.size()
            text.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2))
            return true
        }
        glyph.bounds = CGRect(origin: .zero, size: size)
        glyph.contentsGravity = .resizeAspect
        glyph.transform = CATransform3DMakeScale(Self.rest, Self.rest, 1)
        layer?.addSublayer(glyph)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 19), heightAnchor.constraint(equalToConstant: 19)])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        glyph.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func grow(_ big: Bool) {
        layer?.zPosition = big ? 1 : 0   // over its neighbours while large
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        glyph.transform = CATransform3DMakeScale(big ? 1 : Self.rest, big ? 1 : Self.rest, 1)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func mouseEntered(with event: NSEvent) { grow(true); onHover?(true) }
    override func mouseExited(with event: NSEvent) { grow(false); onHover?(false) }
    override func viewDidHide() { grow(false); onHover?(false) }
    override func mouseDown(with event: NSEvent) {}   // not the table's: no row click or drag from here
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { status.title }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

// A small dark tag with white text, like a tooltip that shows at once.
private final class HintLabel: NSView {
    var text: String { get { label.stringValue } set { label.stringValue = newValue } }
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.15, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

// A chosen status as a label: its emoji and name in its colour, on a light fill of the same colour.
private final class StatusPill: NSView {
    var status: SectionStatus? {
        didSet {
            guard let status, status != oldValue else { return }
            icon.stringValue = status.emoji
            label.stringValue = status.title
            // Darker on light paper, yellow most (it's the faintest), so the name reads on its own tint.
            let darken: CGFloat = status == .idea ? 0.6 : status == .done ? 0.45 : 0.3
            label.textColor = NSColor(name: nil) { $0.isDark ? status.color : status.color.blended(withFraction: darken, of: .black)! }
            needsDisplay = true
        }
    }
    private let icon = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.font = .systemFont(ofSize: 11)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let status else { return }
        status.color.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

// The card's fill: light; for the caret's section a faint caret-colour fill inside a caret-colour outline; darker under the pointer (not while dragging).
private final class OutlineCard: NSView {
    var onHover: ((Bool) -> Void)?
    var isCurrent = false { didSet { if isCurrent != oldValue { needsDisplay = true } } }
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true; onHover?(hovering) } } }
    private var dragging: Bool { (enclosingScrollView?.documentView as? OutlineTable)?.dragging ?? false }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        (isCurrent ? Theme.caret.withAlphaComponent(0.08) : Theme.codeBackground).setFill()
        shape.fill()
        if isCurrent {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 6.25, yRadius: 6.25)
            outline.lineWidth = 1.5
            Theme.caret.withAlphaComponent(0.8).setStroke()
            outline.stroke()
        }
        if hovering {
            LibraryStyle.paletteText.withAlphaComponent(0.06).setFill()
            shape.fill()
        }
    }

    // Also when the card appears or moves under a resting pointer (a rebuilt list, a scroll).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        syncHover()
    }

    override func viewDidMoveToWindow() { syncHover() }

    private func syncHover() {
        guard let window else { hovering = false; return }
        hovering = !dragging && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = !dragging }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
