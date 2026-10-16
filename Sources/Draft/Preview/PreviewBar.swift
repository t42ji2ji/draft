import AppKit

// The preview's bottom bar (iA's IAPreviewToolbarViewController): Web  PDF … template … Split  Full.
// Same height, separator, margins and font as Draft's format bar; the selected item is blue.
final class PreviewBar: NSView {
    var onMode: ((PreviewViewController.DisplayMode) -> Void)?
    var onLayout: ((PreviewViewController.Layout) -> Void)?
    var onTemplate: ((PreviewTemplate) -> Void)?

    private let web = PreviewBar.label("Web")
    private let pdf = PreviewBar.label("PDF")
    private let split = PreviewBar.label("Split")
    private let full = PreviewBar.label("Full")
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    // Values shared with the editor's format bar (docs/library-window.md).
    static let text = NSColor(name: nil) { Palette.current?.text ?? NSColor(white: $0.isDarkPreview ? 0.80 : 0.10, alpha: 1) }
    static let blue = LibraryStyle.blue
    static let separator = NSColor(name: nil) { Palette.current?.separator ?? NSColor(white: $0.isDarkPreview ? 0.13 : 0.93, alpha: 1) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = Self.separator
        web.target = self; web.action = #selector(modeClicked(_:)); web.tag = 0
        pdf.target = self; pdf.action = #selector(modeClicked(_:)); pdf.tag = 1
        split.target = self; split.action = #selector(layoutClicked(_:)); split.tag = PreviewViewController.Layout.split.rawValue
        full.target = self; full.action = #selector(layoutClicked(_:)); full.tag = PreviewViewController.Layout.full.rawValue
        popup.isBordered = false
        popup.font = .systemFont(ofSize: 13)
        popup.target = self
        popup.action = #selector(templateChosen(_:))
        popup.setAccessibilityIdentifier("previewTemplate")
        for t in PreviewTemplate.all { popup.addItem(withTitle: t.name) }
        localize()
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in self?.localize() }

        for v in [line, web, pdf, popup, split, full] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            web.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25),
            web.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            pdf.leadingAnchor.constraint(equalTo: web.trailingAnchor, constant: 17),
            pdf.centerYAnchor.constraint(equalTo: web.centerYAnchor),
            popup.centerXAnchor.constraint(equalTo: centerXAnchor),
            popup.centerYAnchor.constraint(equalTo: web.centerYAnchor),
            full.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -25),
            full.centerYAnchor.constraint(equalTo: web.centerYAnchor),
            split.trailingAnchor.constraint(equalTo: full.leadingAnchor, constant: -17),
            split.centerYAnchor.constraint(equalTo: web.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func label(_ title: String) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.font = .systemFont(ofSize: 13)
        b.setButtonType(.momentaryChange)
        b.setAccessibilityIdentifier("preview" + title)
        return b
    }

    /// Button titles in the current language, keeping each one's colour.
    private func localize() {
        for (b, key) in [(web, "Preview|Web"), (pdf, "PDF"), (split, "Preview|Split"), (full, "Preview|Full")] {
            b.attributedTitle = NSAttributedString(string: L(key), attributes: b.attributedTitle.attributes(at: 0, effectiveRange: nil))
        }
    }

    func update(layout: PreviewViewController.Layout, mode: PreviewViewController.DisplayMode) {
        for (b, on) in [(web, mode == .web), (pdf, mode == .pdf), (split, layout == .split), (full, layout == .full)] {
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: on ? Self.blue : Self.text,
            ])
            b.setAccessibilityValue(on)
        }
    }

    func select(_ template: PreviewTemplate) {
        if let i = PreviewTemplate.all.firstIndex(of: template) { popup.selectItem(at: i) }
    }

    @objc private func modeClicked(_ sender: NSButton) { onMode?(PreviewViewController.DisplayMode(rawValue: sender.tag) ?? .web) }
    @objc private func layoutClicked(_ sender: NSButton) { onLayout?(PreviewViewController.Layout(rawValue: sender.tag) ?? .full) }
    @objc private func templateChosen(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        if PreviewTemplate.all.indices.contains(i) { onTemplate?(PreviewTemplate.all[i]) }
    }
}
