import AppKit

// Settings (⌘,): palette and paper as tiles, then caret colour, font, text size, line length, highlight, CJK emphasis, language.
// The right half is a real editor with sample text, so every change shows as it will look. Changes apply immediately.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var paletteTiles: [Tile] = []
    private var paperTiles: [Tile] = []
    private let paperOpacity = NSSlider(value: 1, minValue: 0.15, maxValue: 1, target: nil, action: nil)
    private let paperOpacityLabel = NSTextField(labelWithString: "")
    private let typeface = NSPopUpButton()
    private let localFontsHeader = NSMenuItem.sectionHeader(title: "")
    private let size = NSPopUpButton()
    private let lineLength = NSPopUpButton()
    private let caret = NSColorWell(style: .minimal)
    private let caretReset = NSButton(title: "", target: nil, action: nil)
    private let highlight = NSPopUpButton()
    private let emphasis = NSPopUpButton()
    private let language = NSPopUpButton()
    private var labels: [(NSTextField, String)] = []   // with their L10n keys, re-read on a language change
    private let previewPane = NSView()
    private let previewScroll = NSScrollView()
    private let previewText = EditorTextView(usingTextLayoutManager: false)

    private static let sample = """
        # 雨天的筆記

        那天下午下著雨，我坐在窗邊寫字。**咖啡**涼了也沒發現。雨聲把整座城市壓得很低，只剩下筆尖的聲音。

        我想起你說過的那句話：*寫下來的，才會留下來。*

        - 帶一本舊書去車站
        - ==記得回那封信==

        It was raining that afternoon, and the coffee went cold.
        """

    private init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        // Tiles: iA's colours first, then Draft's palettes; then the paper patterns.
        let ids = ["ia"] + Palette.all.map(\.id)
        paletteTiles = ids.map { id in
            let tile = Tile(id: "palette-" + id) { Settings.paletteID = id }
            tile.drawContent = { rect in Self.drawPalette(id, in: rect) }
            return tile
        }
        paperTiles = Paper.allCases.map { paper in
            let tile = Tile(id: "paper-\(paper.rawValue)") { Settings.paper = paper }
            tile.drawContent = { rect in Self.drawPaper(paper, in: rect) }
            return tile
        }

        // Titles are set in updateText(); menu items are added directly since addItem(withTitle:) drops duplicates.
        for (popup, count) in [(typeface, Settings.Typeface.allCases.count), (lineLength, Settings.lineLengths.count),
                               (highlight, Settings.Highlight.allCases.count), (emphasis, Settings.CJKEmphasis.allCases.count),
                               (language, L10n.Language.allCases.count)] {
            for _ in 0..<count { popup.menu?.addItem(NSMenuItem()) }
        }
        // The fonts installed on the Mac, under iA's three (the app's own iA fonts left out).
        typeface.menu?.addItem(.separator())
        typeface.menu?.addItem(localFontsHeader)
        for family in NSFontManager.shared.availableFontFamilies where !family.hasPrefix(".") && !family.hasPrefix("iA Writer") {
            let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
            item.representedObject = family
            typeface.menu?.addItem(item)
        }
        for s in Settings.sizes { size.addItem(withTitle: "\(s.name)  ·  \(Int(s.points)) pt") }
        for (item, h) in zip(highlight.itemArray, Settings.Highlight.allCases) { item.image = Self.swatch(h.base) }
        for (popup, action) in [(typeface, #selector(changeTypeface)), (size, #selector(changeSize)), (lineLength, #selector(changeLineLength)),
                                (highlight, #selector(changeHighlight)), (emphasis, #selector(changeEmphasis)), (language, #selector(changeLanguage))] {
            popup.target = self
            popup.action = action
            popup.refusesFirstResponder = true
            popup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }
        caret.target = self
        caret.action = #selector(changeCaret)
        caret.refusesFirstResponder = true
        caretReset.target = self
        caretReset.action = #selector(resetCaret)
        caretReset.controlSize = .small
        caretReset.refusesFirstResponder = true
        let caretRow = NSStackView(views: [caret, caretReset])
        caretRow.spacing = 8

        let label = { (key: String) -> NSTextField in
            let l = NSTextField(labelWithString: "")
            l.alignment = .right
            self.labels.append((l, key))
            return l
        }
        let header = { (key: String) -> NSTextField in
            let h = Self.header()
            self.labels.append((h, key))
            return h
        }
        let form = NSGridView(views: [
            [label("Cursor:"), caretRow],
            [label("Font:"), typeface],
            [label("Text size:"), size],
            [label("Line length:"), lineLength],
            [label("Highlight:"), highlight],
            [label("Chinese emphasis:"), emphasis],
            [label("Language:"), language],
        ])
        form.rowSpacing = 10
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.rowAlignment = .firstBaseline

        paperOpacity.isContinuous = true
        paperOpacity.target = self
        paperOpacity.action = #selector(changePaperOpacity)
        paperOpacity.controlSize = .small
        paperOpacity.widthAnchor.constraint(equalToConstant: 200).isActive = true
        paperOpacityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        paperOpacityLabel.textColor = .secondaryLabelColor
        let opacityTitle = label("Opacity")
        opacityTitle.alignment = .natural
        opacityTitle.font = .systemFont(ofSize: 12)
        let opacityRow = NSStackView(views: [opacityTitle, paperOpacity, paperOpacityLabel])
        opacityRow.spacing = 8

        let controls = NSStackView(views: [
            header("Colours"), Self.tileGrid(paletteTiles, columns: 7),
            header("Paper"), Self.tileGrid(paperTiles, columns: 7), opacityRow,
            header("Text"), form,
        ])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        controls.setCustomSpacing(22, after: controls.arrangedSubviews[1])
        controls.setCustomSpacing(22, after: controls.arrangedSubviews[4])

        buildPreview()

        let content = NSView()
        for v in [controls, previewPane] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            previewPane.topAnchor.constraint(equalTo: content.topAnchor),
            previewPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            previewPane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            previewPane.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 24),
            previewPane.widthAnchor.constraint(equalToConstant: 500),   // > 440: the editor's regular size class
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])
        window.contentView = content
        window.initialFirstResponder = previewText

        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: Settings.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: Settings.caretColorDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateText), name: L10n.didChange, object: nil)
        updateText()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Every piece of text in the window, in the current language. The window refits around the new label widths.
    @objc private func updateText() {
        guard let window else { return }
        window.title = L("Settings")
        caretReset.title = L("Use Palette's")
        localFontsHeader.title = L("Fonts on This Mac")
        for (label, key) in labels { label.stringValue = L(key) }
        for (tile, id) in zip(paletteTiles, ["ia"] + Palette.all.map(\.id)) { tile.name = Palette.all.first { $0.id == id }?.title ?? L("System") }
        for (tile, paper) in zip(paperTiles, Paper.allCases) { tile.name = paper.title }
        let titles: [(NSPopUpButton, [String])] = [
            (typeface, Settings.Typeface.allCases.map(\.title)),
            (lineLength, Settings.lineLengths.map { String(format: L("%d characters"), Int($0)) }),
            (highlight, Settings.Highlight.allCases.map(\.title)),
            (emphasis, Settings.CJKEmphasis.allCases.map(\.title)),
            // The two languages are always named in themselves.
            (language, [L("Follow System"), "English", "繁體中文"]),
        ]
        for (popup, names) in titles {
            for (item, name) in zip(popup.itemArray, names) { item.title = name }
            popup.synchronizeTitleAndSelectedItem()
        }
        sync()
        let top = window.frame.maxY
        window.setContentSize(window.contentView!.fittingSize)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
    }

    private func buildPreview() {
        previewScroll.hasVerticalScroller = true
        previewScroll.verticalScroller = ThinScroller()
        previewScroll.autohidesScrollers = true
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = Theme.background
        previewScroll.borderType = .noBorder
        previewScroll.documentView = previewText
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewPane.addSubview(previewScroll)
        NSLayoutConstraint.activate([
            previewScroll.topAnchor.constraint(equalTo: previewPane.topAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
            previewScroll.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
        ])
        previewText.autoresizingMask = [.width]
        previewText.string = Self.sample
        previewText.configure()
        // Caret after 聲音, with 筆尖 selected, so caret and selection colours both show.
        let ns = Self.sample as NSString
        previewText.setSelectedRange(ns.range(of: "筆尖"))
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: previewScroll, queue: .main) { [weak self] _ in
            self?.previewText.relayout()
        }
    }

    // Reflect the stored values (they also change from ⌘+ / ⌘− and the menus).
    @objc private func sync() {
        for (tile, id) in zip(paletteTiles, ["ia"] + Palette.all.map(\.id)) { tile.selected = id == Settings.paletteID }
        for (tile, paper) in zip(paperTiles, Paper.allCases) { tile.selected = paper == Settings.paper; tile.needsDisplay = true }
        paperOpacity.doubleValue = Settings.paperOpacity
        paperOpacity.isEnabled = Settings.paper != .none
        paperOpacityLabel.stringValue = "\(Int((Settings.paperOpacity * 100).rounded())) %"
        if let family = Settings.localFont, let item = typeface.itemArray.first(where: { $0.representedObject as? String == family }) {
            typeface.select(item)
        } else {
            typeface.selectItem(at: Settings.typeface.rawValue)
        }
        size.selectItem(at: Settings.sizeIndex)
        lineLength.selectItem(at: Settings.lineLengths.firstIndex(of: Settings.lineLength) ?? 0)
        highlight.selectItem(at: Settings.highlight.rawValue)
        emphasis.selectItem(at: Settings.cjkEmphasis.rawValue)
        language.selectItem(at: L10n.language.rawValue)
        caret.color = Settings.caretColor
        caretReset.isEnabled = Settings.customCaretColor != nil
        // The preview takes the palette's light/dark like the library window does.
        previewPane.appearance = Palette.current.map { NSAppearance(named: $0.isDark ? .darkAqua : .aqua) } ?? nil
        // The whole window too, on the palette's chrome colour like the library tree.
        window?.appearance = previewPane.appearance
        window?.backgroundColor = Palette.current?.chrome ?? .windowBackgroundColor
        window?.titlebarAppearsTransparent = Palette.current != nil
        previewScroll.backgroundColor = Palette.current?.bg ?? Theme.background   // the same dynamic colour again wouldn't redraw
        previewText.relayout()
    }

    @objc private func changePaperOpacity() {
        Settings.paperOpacity = paperOpacity.doubleValue
        paperOpacityLabel.stringValue = "\(Int((Settings.paperOpacity * 100).rounded())) %"
    }
    @objc private func changeTypeface() {
        if let family = typeface.selectedItem?.representedObject as? String {
            Settings.setFont(Settings.typeface, local: family)
        } else {
            Settings.setFont(Settings.Typeface(rawValue: typeface.indexOfSelectedItem) ?? .mono)
        }
    }
    @objc private func changeSize() { Settings.sizeIndex = size.indexOfSelectedItem }
    @objc private func changeLineLength() { Settings.lineLength = Settings.lineLengths[lineLength.indexOfSelectedItem] }
    @objc private func changeCaret() { Settings.customCaretColor = caret.color }
    @objc private func resetCaret() { Settings.customCaretColor = nil }
    @objc private func changeHighlight() { Settings.highlight = Settings.Highlight(rawValue: highlight.indexOfSelectedItem) ?? .green }
    @objc private func changeEmphasis() { Settings.cjkEmphasis = Settings.CJKEmphasis(rawValue: emphasis.indexOfSelectedItem) ?? .marks }

    @objc private func changeLanguage() { L10n.language = L10n.Language(rawValue: language.indexOfSelectedItem) ?? .system }

    // MARK: - Drawing

    // A small page: background, two lines of text, a caret. iA's tile is split light | dark (it follows the system).
    private static func drawPalette(_ id: String, in rect: NSRect) {
        let halves: [(NSColor, NSColor, NSColor, NSRect)]
        if let p = Palette.all.first(where: { $0.id == id }) {
            halves = [(p.bg, p.text, p.caret, rect)]
        } else {
            let (l, r) = rect.divided(atDistance: rect.width / 2, from: .minXEdge)
            let blue = Settings.iaCaretColor
            halves = [(NSColor(white: 0.96, alpha: 1), NSColor(white: 0.10, alpha: 1), blue, l),
                      (NSColor(white: 0.08, alpha: 1), NSColor(white: 0.80, alpha: 1), blue, r)]
        }
        for (bg, _, _, r) in halves { bg.setFill(); r.fill() }
        let (_, text, caret, _) = halves[0]
        let font = NSFont(name: "iAWriterMonoV-Regular", size: 15) ?? .systemFont(ofSize: 15)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: halves.count > 1 ? NSColor.clear : text]
        let glyph = NSAttributedString(string: "Aa", attributes: attrs)
        let at = NSPoint(x: rect.minX + 9, y: rect.midY - glyph.size().height / 2)
        if halves.count > 1 {
            for (_, t, _, r) in halves {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: r).addClip()
                NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: t]).draw(at: at)
                NSGraphicsContext.restoreGraphicsState()
            }
        } else {
            glyph.draw(at: at)
        }
        caret.setFill()
        NSRect(x: at.x + glyph.size().width + 2, y: rect.midY - 8, width: 2, height: 16).fill()
    }

    // The pattern in the current palette's colours, at a small pitch.
    private static func drawPaper(_ paper: Paper, in rect: NSRect) {
        let p = Palette.current
        (p?.bg ?? NSColor(white: 0.96, alpha: 1)).setFill()
        rect.fill()
        let line = p?.paperLine ?? NSColor(white: 0.80, alpha: 1)
        let margin = p?.margin ?? Settings.iaCaretColor.withAlphaComponent(0.45)
        paper.draw(in: rect, top: rect.minY + 2, pitch: 9, left: rect.minX + 8, line: line, margin: margin)
    }

    private static func header() -> NSTextField {
        let h = NSTextField(labelWithString: "")
        h.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return h
    }

    private static func tileGrid(_ tiles: [Tile], columns: Int) -> NSGridView {
        let rows = stride(from: 0, to: tiles.count, by: columns).map { start in
            (0..<columns).map { start + $0 < tiles.count ? tiles[start + $0] as NSView : NSGridCell.emptyContentView }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        return grid
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

// A clickable picture with a name under it; a ring marks the selected one. Never takes focus from the preview.
private final class Tile: NSView {
    var drawContent: ((NSRect) -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    var name = "" {
        didSet {
            toolTip = name
            setAccessibilityLabel(name)
            needsDisplay = true
        }
    }
    private let action: () -> Void
    private static let picture = NSSize(width: 58, height: 40)

    init(id: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.picture.width, height: Self.picture.height + 18)))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(id)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { frame.size }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(origin: .zero, size: Self.picture).insetBy(dx: 2, dy: 2)
        let shape = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        drawContent?(box)
        NSGraphicsContext.restoreGraphicsState()
        if selected {
            (Palette.current != nil ? Theme.caret : NSColor.controlAccentColor).setStroke()
            let ring = NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: -1), xRadius: 7, yRadius: 7)
            ring.lineWidth = 2.5
            ring.stroke()
        } else {
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let font = NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
            .draw(in: NSRect(x: -6, y: Self.picture.height + 2, width: bounds.width + 12, height: 16))
    }
}

// App menu › Settings…, View › Bigger / Smaller / Actual Size (iA's ⌘+ / ⌘− / ⌘0 step through the sizes).
extension AppDelegate {
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.showWindow(sender) }
    @objc func biggerText(_ sender: Any?) { Settings.sizeIndex += 1 }
    @objc func smallerText(_ sender: Any?) { Settings.sizeIndex -= 1 }
    @objc func actualSizeText(_ sender: Any?) { Settings.sizeIndex = Settings.defaultSizeIndex }
}
