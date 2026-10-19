import AppKit

// iA's bottom bar: Body, Heading 1, List, Blockquote | Bold, Italic, Strikethrough | Link, Wikilink, Footnote, Table, TOC … word count.
final class FormatBar: NSView {
    enum Action: Int {
        case body, heading, list, blockquote, bold, italic, strikethrough, link, wikilink, footnote, table, toc
    }

    var onAction: ((Action, Int) -> Void)?
    private var labels: [Action: FormatLabel] = [:]
    private var titles: [Action: String] = [:]
    private static let tips: [Action: String] = [
        .body: "Body text (⌥⌘0)", .heading: "Heading level (⌥⌘1–3)", .list: "List: to-do ⌥⌘4, bulleted ⌥⌘5, numbered ⌥⌘6",
        .blockquote: "Quote the paragraph", .bold: "Bold (⌘B)", .italic: "Italic (⌘I)", .strikethrough: "Strikethrough (⇧⌘S)",
        .link: "Link (⌘K)", .wikilink: "Link to another document [[ ]]", .footnote: "Add a footnote", .table: "Insert a table",
        .toc: "Insert a table of contents",
    ]
    private let count = FormatLabel()
    private var showCharacters = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The bar sits over the editor; without this the text view's I-beam shows through it.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        let line = SeparatorView()
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 20
        stack.alignment = .centerY
        let groups: [[(Action, String)]] = [
            [(.body, "Body"), (.heading, "Heading 1"), (.list, "List"), (.blockquote, "Blockquote")],
            [(.bold, "Bold"), (.italic, "Italic"), (.strikethrough, "Strikethrough")],
            [(.link, "Link"), (.wikilink, "Wikilink"), (.footnote, "Footnote"), (.table, "Table"), (.toc, "TOC")],
        ]
        for (g, group) in groups.enumerated() {
            if g > 0 {
                let divider = SeparatorView()
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
                if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }
                stack.addArrangedSubview(divider)
                stack.setCustomSpacing(16, after: divider)
            }
            for (action, title) in group {
                let label = FormatLabel()
                titles[action] = title
                label.chevron = action == .heading || action == .list
                switch action {
                case .bold: label.font = .systemFont(ofSize: 13, weight: .semibold)
                case .italic: label.font = NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
                case .strikethrough: label.strike = true
                default: break
                }
                label.onClick = { [weak self, weak label] in self?.clicked(action, label) }
                labels[action] = label
                stack.addArrangedSubview(label)
                // Measured: iA's gaps after Body and Heading are 3 pt tighter.
                if action == .body || action == .heading { stack.setCustomSpacing(17, after: label) }
            }
        }
        count.chevron = true
        count.onClick = { [weak self] in self?.countMenu() }
        applyLanguage()
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in self?.applyLanguage() }
        // The buttons sit in a clipping box so a narrow pane cuts them off instead of widening the window.
        let box = NSView()
        box.clipsToBounds = true
        for v in [box, count] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25),
            box.topAnchor.constraint(equalTo: line.bottomAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: -0.5),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -25),
            count.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // The bar picks the cursor itself, so the buttons get the hand even where the editor's cursor rects lie underneath.
    override func cursorUpdate(with event: NSEvent) { setCursor(event) }
    override func mouseMoved(with event: NSEvent) { setCursor(event) }
    private func setCursor(_ event: NSEvent) {
        let hit = superview.flatMap { hitTest($0.convert(event.locationInWindow, from: nil)) }
        (hit is FormatLabel ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
    }

    private func applyLanguage() {
        for (action, label) in labels { label.title = L(titles[action]!); label.toolTip = Self.tips[action].map(L) }
        count.toolTip = L("Switch between words and characters")
        update(block: lastBlock, text: lastText)
    }

    // Which block style the caret is in: highlights Body / Heading n / List / Blockquote.
    private var lastBlock: (Action, Int) = (.body, 0)
    func update(block: (Action, Int), text: String) {
        lastBlock = block
        for (action, label) in labels { label.active = action == block.0 }
        labels[.heading]?.title = String(format: L("Heading %d"), block.0 == .heading ? block.1 : 1)
        updateCount(text)
    }

    private var lastText = ""
    func updateCount(_ text: String) {
        lastText = text
        if showCharacters {
            let n = text.filter { !$0.isNewline }.count
            count.title = String(format: L(n == 1 ? "%@ Character" : "%@ Characters"), Self.number(n))
        } else {
            let n = WordCount.words(in: text)
            count.title = String(format: L(n == 1 ? "%@ Word" : "%@ Words"), Self.number(n))
        }
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    private static func number(_ n: Int) -> String { formatter.string(from: NSNumber(value: n)) ?? "\(n)" }

    private func clicked(_ action: Action, _ label: FormatLabel?) {
        switch action {
        case .heading:
            popUp((1...6).map { String(format: L("Heading %d"), $0) }, under: label) { self.onAction?(.heading, $0 + 1) }
        case .list:
            popUp([L("Unordered List"), L("Ordered List"), L("Task List")], under: label) { self.onAction?(.list, $0) }
        default:
            onAction?(action, 0)
        }
    }

    private func countMenu() {
        popUp([L("Words"), L("Characters")], under: count, checked: showCharacters ? 1 : 0) {
            self.showCharacters = $0 == 1
            self.updateCount(self.lastText)
        }
    }

    private func popUp(_ titles: [String], under view: NSView?, checked: Int? = nil, _ pick: @escaping (Int) -> Void) {
        guard let view else { return }
        let menu = NSMenu()
        for (i, t) in titles.enumerated() {
            let item = MenuClosureItem(title: t) { pick(i) }
            item.state = i == checked ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }
}

final class MenuClosureItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

// A borderless text button sized to its text, optionally with an up/down chevron.
final class FormatLabel: NSView {
    var title = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 13) { didSet { invalidateIntrinsicContentSize() } }
    var strike = false
    var chevron = false
    var active = false { didSet { if active != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?

    private static let chevronImage = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold))

    private var attributes: [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: active ? LibraryStyle.blue : LibraryStyle.formatText]
        if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    override var intrinsicContentSize: NSSize {
        let w = ceil((title as NSString).size(withAttributes: attributes).width) + (chevron ? 10 : 0)
        return NSSize(width: w, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 0, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if chevron, let image = Self.chevronImage?.tinted(active ? LibraryStyle.blue : LibraryStyle.formatText) {
            let s = image.size
            image.draw(in: NSRect(x: ceil(size.width) + 3, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
        }
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
