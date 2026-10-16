import AppKit

// iA's IABarVisibilityAgent (docs/bar-visibility.md): typing or scrolling the editor fades the title bar and the
// bottom bar; moving the mouse near the top or bottom edge brings them back. Text never moves.
final class BarVisibility: NSResponder {
    // `TitlebarVisibility`: 0 fade, 1 always. `ToolbarVisibility` (bottom bar): 0 fade, 1 always, 2 hide.
    static var titlebarSetting: Int { min(UserDefaults.standard.integer(forKey: "TitlebarVisibility"), 1) }
    static var bottomBarSetting: Int { min(max(UserDefaults.standard.integer(forKey: "ToolbarVisibility"), 0), 2) }

    private weak var window: NSWindow?
    private let bottomBar: NSView
    private let titlebarBand: NSView
    private let scrollView: NSScrollView
    private let libraryCollapsed: () -> Bool
    private var titlebarHidden = false
    private var bottomHidden = false
    private var generation = 0
    private var hiddenTitleViews: [NSView] = []
    private var lastKey: TimeInterval = 0
    private var keyMonitor: Any?

    init(window: NSWindow, bottomBar: NSView, titlebarBand: NSView, textView: NSTextView, scrollView: NSScrollView,
         libraryCollapsed: @escaping () -> Bool) {
        self.window = window
        self.bottomBar = bottomBar
        self.titlebarBand = titlebarBand
        self.scrollView = scrollView
        self.libraryCollapsed = libraryCollapsed
        super.init()
        // Input methods (注音) hand text back after the key event is done, so the time of the last key press is kept.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if !event.modifierFlags.contains(.command) { self?.lastKey = event.timestamp }
            return event
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(scrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        if let content = window.contentView {
            content.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
        applyBottomSetting()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Only a key press that changes text counts; menu pastes and caret moves don't.
    @objc private func textChanged() {
        guard ProcessInfo.processInfo.systemUptime - lastKey < 1 else { return }
        hide(pointerAware: false)
    }

    @objc private func scrollStarted() { hide(pointerAware: true) }

    private func hide(pointerAware: Bool) {
        guard let window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        if Self.bottomBarSetting == 0, !(pointerAware && inBottomZone(point)) { setBottomHidden(true) }
        // With the library open, the title bar stays.
        if Self.titlebarSetting == 0, libraryCollapsed(), !(pointerAware && inTopZone(point)),
           !window.styleMask.contains(.fullScreen), window.attachedSheet == nil, !scrollView.isFindBarVisible,
           NSEvent.pressedMouseButtons & 1 == 0 {
            setTitlebarHidden(true)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if inBottomZone(event.locationInWindow) && Self.bottomBarSetting == 0 { setBottomHidden(false) }
        if inTopZone(event.locationInWindow) { setTitlebarHidden(false) }
    }

    // Bottom bar plus half its height toward the text.
    private func inBottomZone(_ point: NSPoint) -> Bool {
        let frame = bottomBar.convert(bottomBar.bounds, to: nil)
        return point.x >= frame.minX && point.x <= frame.maxX && point.y <= frame.maxY + frame.height / 2
    }

    // Title bar height + 20 pt from the top of the window.
    private func inTopZone(_ point: NSPoint) -> Bool {
        guard let window, let content = window.contentView, !window.styleMask.contains(.fullScreen) else { return false }
        let titlebar = window.frame.height - window.contentLayoutRect.height
        return point.y >= content.bounds.height - titlebar - 20
    }

    // MARK: - Fades (0.15 s; a show cancels a pending hide through `generation`)

    func setTitlebarHidden(_ hidden: Bool) {
        guard hidden != titlebarHidden else { return }
        titlebarHidden = hidden
        generation += 1
        let token = generation
        let views: [NSView]
        if hidden {
            // The whole title bar, traffic lights included, and the band behind it.
            views = [window?.standardWindowButton(.closeButton)?.superview?.superview, titlebarBand].compactMap { $0 }
            hiddenTitleViews = views
        } else {
            views = hiddenTitleViews
            views.forEach { $0.isHidden = false }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            views.forEach { $0.animator().alphaValue = hidden ? 0 : 1 }
        }, completionHandler: { [weak self] in
            guard let self, hidden, token == self.generation else { return }
            views.forEach { $0.isHidden = true }
        })
    }

    private func setBottomHidden(_ hidden: Bool) {
        guard hidden != bottomHidden else { return }
        bottomHidden = hidden
        if !hidden { bottomBar.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: hidden ? .easeIn : .easeOut)
            bottomBar.animator().alphaValue = hidden ? 0 : 1
        }, completionHandler: { [weak self] in
            guard let self, hidden, self.bottomHidden else { return }
            self.bottomBar.isHidden = true
        })
    }

    // "Hide" keeps the bottom bar away; "Always Show" brings it back.
    func applyBottomSetting() {
        switch Self.bottomBarSetting {
        case 2: setBottomHidden(true)
        case 1: setBottomHidden(false)
        default: break
        }
    }

    // A library toggle reveals the title bar, as in iA.
    func libraryToggled() { setTitlebarHidden(false) }
}

// View › Title Bar / Toolbar, as in iA.
extension LibraryWindowController {
    @objc func changeTitlebarVisibility(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "TitlebarVisibility")
        if sender.tag == 1 { bars?.setTitlebarHidden(false) }
    }

    @objc func changeToolbarVisibility(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "ToolbarVisibility")
        bars?.applyBottomSetting()
    }

    // The focus menu's switch: both bars fade, or both always show.
    @objc func toggleBarFade(_ sender: NSMenuItem) {
        let value = BarVisibility.titlebarSetting == 0 ? 1 : 0
        UserDefaults.standard.set(value, forKey: "TitlebarVisibility")
        UserDefaults.standard.set(value, forKey: "ToolbarVisibility")
        if value == 1 { bars?.setTitlebarHidden(false) }
        bars?.applyBottomSetting()
    }
}
