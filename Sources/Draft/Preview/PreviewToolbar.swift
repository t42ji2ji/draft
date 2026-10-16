import AppKit

// The three items at the right end of iA Writer's editor toolbar (docs/preview.md §1):
//   ≡ ⌄  Focus (IAToolbarFocusSegmentedControlItemIdentifier): left half toggles Focus Mode (⌘D),
//        the chevron opens the focus menu (Sentence / Paragraph / Typewriter).
//   Syntax, Style Check: Draft additions shaped like Focus: the left half toggles it, the chevron opens the
//        Focus menu's Syntax or Style Check section.
//   (iA's 🔍 Quick Search, ⇧⌘O, sits between them; Draft has no Quick Search yet, so it's left out.)
//   ▶    Preview (IAToolbarPreviewItemIdentifier): ⌘R, a toggle that shows whether the preview is visible.
// Actions go up the responder chain (nil target), so whoever implements the selector handles them.
final class PreviewToolbar: NSObject {
    static let focus = NSToolbarItem.Identifier("IAToolbarFocusSegmentedControlItemIdentifier")
    static let preview = NSToolbarItem.Identifier("IAToolbarPreviewItemIdentifier")
    static let syntax = NSToolbarItem.Identifier("syntax")
    static let style = NSToolbarItem.Identifier("styleCheck")
    static let identifiers = [focus, syntax, style, preview]

    static let toggleFocusMode = NSSelectorFromString("toggleFocusMode:")
    static let selectFocusScope = NSSelectorFromString("selectFocusScope:")
    static let togglePreview = NSSelectorFromString("togglePreview:")

    // Focus, Syntax and Style Check: [icon | ⌄], the icon segment selected while it's on.
    private var controls: [NSToolbarItem.Identifier: NSSegmentedControl] = [:]
    private static let toggles = [focus: toggleFocusMode, syntax: #selector(EditorTextView.toggleSyntaxControl(_:)),
                                  style: #selector(EditorTextView.toggleStyleCheck(_:))]
    private var previewButton: NSButton?
    private let items = NSHashTable<NSToolbarItem>.weakObjects()

    var focusEnabled = false { didSet { controls[Self.focus]?.setSelected(focusEnabled, forSegment: 0) } }
    var syntaxEnabled = false { didSet { controls[Self.syntax]?.setSelected(syntaxEnabled, forSegment: 0) } }
    var styleEnabled = false { didSet { controls[Self.style]?.setSelected(styleEnabled, forSegment: 0) } }
    var previewVisible = false { didSet { updatePreviewButton() } }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.items.allObjects.forEach { self?.localize($0) }
        }
    }

    func item(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch identifier {
        case Self.focus, Self.syntax, Self.style: item = splitItem(identifier)
        case Self.preview: item = previewItem()
        default: return nil
        }
        items.add(item)
        localize(item)
        return item
    }

    /// The item's text in the current language; also run on `L10n.didChange`.
    private func localize(_ item: NSToolbarItem) {
        switch item.itemIdentifier {
        case Self.focus:
            // iA draws its own "focus-3.0" image; text.alignleft is the closest SF Symbol (deviation, see docs).
            let control = item.view as? NSSegmentedControl
            control?.setImage(NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: L("Focus")), forSegment: 0)
            control?.setMenu(Self.focusMenu(), forSegment: 1)
            control?.setToolTip(L("Focus Mode (⌘D)"), forSegment: 0)
            control?.setToolTip(L("Focus Scope and More"), forSegment: 1)
            item.label = L("Focus")
            item.toolTip = L("Focus Mode (⌘D)")
        case Self.syntax:
            setMenu(item, label: "Syntax", symbol: "highlighter", toolTip: "Highlight Parts of Speech (⇧⌘D)",
                    toggle: ("Show Syntax", #selector(EditorTextView.toggleSyntaxControl(_:)), #selector(EditorTextView.toggleSyntaxTarget(_:))),
                    targets: [("Adjectives", PartOfSpeech.adjective.rawValue), ("Nouns", PartOfSpeech.noun.rawValue), ("Adverbs", PartOfSpeech.adverb.rawValue),
                              ("Verbs", PartOfSpeech.verb.rawValue), ("Conjunctions", PartOfSpeech.conjunction.rawValue)])
        case Self.style:
            setMenu(item, label: "Style Check", symbol: "checkmark.seal", toolTip: "Style Check (⌥⇧⌘D)",
                    toggle: ("Enable Style Check", #selector(EditorTextView.toggleStyleCheck(_:)), #selector(EditorTextView.toggleStyleTarget(_:))),
                    targets: [("Fillers", StyleCategory.fillers.rawValue), ("Clichés", StyleCategory.cliches.rawValue), ("Redundancies", StyleCategory.redundancies.rawValue)])
        case Self.preview:
            item.label = L("Preview")
            item.toolTip = L("Preview (⌘R)")
            item.view?.toolTip = item.toolTip
            item.view?.setAccessibilityLabel(L("Preview"))
            updatePreviewButton()
        default: break
        }
    }

    private func splitItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .selectAny
        control.segmentStyle = .separated
        control.setImageScaling(.scaleProportionallyDown, forSegment: 0)
        control.setWidth(34, forSegment: 0)
        control.setShowsMenuIndicator(true, forSegment: 1)
        control.setWidth(22, forSegment: 1)
        control.target = self
        control.action = #selector(splitClicked(_:))
        control.setAccessibilityIdentifier(identifier == Self.focus ? "focusMode" : identifier.rawValue)
        controls[identifier] = control
        control.setSelected(enabled(identifier), forSegment: 0)

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = control
        return item
    }

    // The icon toggles the whole set; the menu repeats that toggle, then picks what's marked. EditorTextView validates both.
    private func setMenu(_ item: NSToolbarItem, label: String, symbol: String, toolTip: String,
                         toggle: (String, Selector, Selector), targets: [(String, Int)]) {
        let menu = NSMenu()
        menu.addItem(withTitle: L(toggle.0), action: toggle.1, keyEquivalent: "")
        menu.addItem(.separator())
        for (title, tag) in targets {
            menu.addItem(withTitle: L(title), action: toggle.2, keyEquivalent: "").tag = tag
        }
        let control = item.view as? NSSegmentedControl
        control?.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: L(label)), forSegment: 0)
        control?.setMenu(menu, forSegment: 1)
        control?.setToolTip(L(toolTip), forSegment: 0)
        control?.setToolTip(L(label), forSegment: 1)
        item.label = L(label)
        item.toolTip = L(toolTip)
    }

    /// Same items and tags as iA's Focus menu (tags match Draft's EditorTextView.FocusScope).
    static func focusMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, tag, symbol) in [("Sentence", 2, "text.cursor"), ("Paragraph", 1, "paragraphsign"), ("Typewriter", 0, "keyboard")] {
            let item = menu.addItem(withTitle: L(title), action: selectFocusScope, keyEquivalent: "")
            item.tag = tag
            item.attributedTitle = iconTitle(item.title, symbol: symbol)
        }
        // Draft addition: View › Title Bar and Toolbar "Fade In/Out" together, ticked while on.
        menu.addItem(.separator())
        let bars = menu.addItem(withTitle: L("Hide Bars While Typing"), action: NSSelectorFromString("toggleBarFade:"), keyEquivalent: "")
        bars.attributedTitle = iconTitle(bars.title, symbol: "eye.slash")
        return menu
    }

    // The icon goes in the title: a checked item's checkmark would replace `NSMenuItem.image`.
    private static func iconTitle(_ title: String, symbol: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "  " + title))
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func enabled(_ identifier: NSToolbarItem.Identifier) -> Bool {
        [Self.focus: focusEnabled, Self.syntax: syntaxEnabled, Self.style: styleEnabled][identifier] ?? false
    }

    @objc private func splitClicked(_ sender: NSSegmentedControl) {
        guard let identifier = controls.first(where: { $0.value === sender })?.key else { return }
        // Segment 1 is never left selected, so a selected segment 1 means the chevron was clicked.
        if !sender.isSelected(forSegment: 1) {
            NSApp.sendAction(Self.toggles[identifier]!, to: nil, from: sender)
        } else if let menu = sender.menu(forSegment: 1) {
            sender.setSelected(false, forSegment: 1)
            // Clicking the chevron (not only press-and-hold) opens the menu, as in iA.
            let x = sender.width(forSegment: 0) + 4
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: sender.bounds.maxY + 4), in: sender)
        }
        sender.setSelected(enabled(identifier), forSegment: 0)
    }

    private func previewItem() -> NSToolbarItem {
        let button = NSButton(image: NSImage(systemSymbolName: "play", accessibilityDescription: nil)!, target: nil, action: Self.togglePreview)
        button.bezelStyle = .texturedRounded
        button.setButtonType(.pushOnPushOff)
        button.setAccessibilityIdentifier("previewToggle")
        previewButton = button
        let item = NSToolbarItem(itemIdentifier: Self.preview)
        item.view = button
        return item
    }

    private func updatePreviewButton() {
        previewButton?.state = previewVisible ? .on : .off
        // iA switches the image with `previewButtonImageForPreviewVisible:`; filled while visible (inferred).
        previewButton?.image = NSImage(systemSymbolName: previewVisible ? "play.fill" : "play", accessibilityDescription: L("Preview"))
    }
}
