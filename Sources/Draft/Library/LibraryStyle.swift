import AppKit

// Library window values; sources in docs/library-window.md.
enum LibraryStyle {
    // NSColor(Writer) writerLibrary* (colorWithWhite:, light / dark).
    static let separator = NSColor(name: nil) { Palette.current?.separator ?? NSColor(white: $0.isDark ? 0.13 : 0.93, alpha: 1) }  // glass branch
    static let formatText = NSColor(name: nil) { Palette.current?.text ?? NSColor(white: $0.isDark ? 0.80 : 0.10, alpha: 1) }   // editor text colour; the format bar uses it
    // The bars' selected item: iA blue, or the caret colour with a palette.
    static let blue = NSColor(name: nil) { _ in Palette.current != nil ? Theme.caret : NSColor(displayP3Red: 0, green: 0.75, blue: 1, alpha: 1) }

    // Library tree and outline: the palette's colours when one is chosen, otherwise the system's.
    static let paletteText = NSColor(name: nil) { _ in Palette.current?.text ?? .labelColor }
    static let paletteSecondaryText = NSColor(name: nil) { _ in Palette.current?.syntax ?? .secondaryLabelColor }

    // Sidebar icon tints (InterfaceFoundation asset catalog); with a palette, folders take the caret colour and the
    // rest the palette's grey.
    static let folderTint = NSColor(name: nil) { _ in Palette.current != nil ? Theme.caret : hex(0x00C7FF) }
    static let hashtagTint = NSColor(name: nil) { _ in Palette.current?.syntax ?? hex(0x8E8E93) }

    // An expanded folder: SF Symbols has no open folder, so it's drawn to match folder.fill at 13 pt (template, tinted
    // like the symbol): the back with its tab, and the front flap tilted forward with a gap above it.
    static let openFolder: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            NSColor.black.setFill()
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 1.5, y: 2))
            back.line(to: NSPoint(x: 1.5, y: 11.2))
            back.curve(to: NSPoint(x: 2.8, y: 12.5), controlPoint1: NSPoint(x: 1.5, y: 12), controlPoint2: NSPoint(x: 2, y: 12.5))
            back.line(to: NSPoint(x: 6.2, y: 12.5))
            back.line(to: NSPoint(x: 7.6, y: 11))
            back.line(to: NSPoint(x: 14, y: 11))
            back.curve(to: NSPoint(x: 15.2, y: 9.8), controlPoint1: NSPoint(x: 14.7, y: 11), controlPoint2: NSPoint(x: 15.2, y: 10.5))
            back.line(to: NSPoint(x: 15.2, y: 2))
            back.close()
            back.fill()
            let flap = NSBezierPath()
            flap.move(to: NSPoint(x: 1.5, y: 1.2))
            flap.line(to: NSPoint(x: 14.6, y: 1.2))
            flap.line(to: NSPoint(x: 17.4, y: 8.4))
            flap.line(to: NSPoint(x: 4.3, y: 8.4))
            flap.close()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            flap.lineWidth = 2.2
            flap.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            flap.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    // The library tree's first-run width: iA's sidebar (158) is too narrow once it lists file names.
    static let sidebarWidth: CGFloat = 240
    static let outlineWidth: CGFloat = 200
    // Measured at 2× on iA Writer 8.0.6, macOS 27.
    static let bottomBarHeight: CGFloat = 39

    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// Fills with the palette's chrome colour; with iA's colours it draws nothing, so the sidebar material shows.
final class PaletteBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let palette = Palette.current else { return }
        palette.chrome.setFill()
        dirtyRect.fill()
    }
}

// Column dividers in the palette's separator colour; the system's with iA's colours.
final class PaletteSplitView: NSSplitView {
    var hiddenDividers: Set<Int> = []   // still draggable, drawn in the page colour
    override var dividerColor: NSColor { Palette.current != nil ? LibraryStyle.separator : super.dividerColor }

    override func drawDivider(in rect: NSRect) {
        let index = arrangedSubviews.firstIndex { abs($0.frame.maxX - rect.minX) < 0.5 && !isSubviewCollapsed($0) }
        if let index, hiddenDividers.contains(index) { Theme.background.setFill(); rect.fill(); return }
        super.drawDivider(in: rect)
    }
}

// Selected row in the palette's selection colour, never emphasized (the palette's text stays readable);
// the system's highlight with iA's colours.
final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { Palette.current == nil && super.isEmphasized }
        set { super.isEmphasized = newValue }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let palette = Palette.current else { return super.drawSelection(in: dirtyRect) }
        palette.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
}

// Every scroll bar in the app (editor, library, outline, assistant, Settings preview): a thin rounded knob in the syntax grey (the palette's with a palette), no track.
// Narrower than the system's in both overlay and always-shown styles; a little wider while the pointer is on it.
final class ThinScroller: NSScroller {
    private var hovering = false

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 10 }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let width: CGFloat = hovering ? 6 : 4
        let bar = NSRect(x: bounds.maxX - width - 2, y: knob.minY + 2, width: width, height: knob.height - 4)
        Theme.syntax.withAlphaComponent(hovering ? 0.9 : 0.6).setFill()
        NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hovering = false; needsDisplay = true }
}

final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        LibraryStyle.separator.setFill()
        bounds.fill()
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

// CJK ideographs, kana and hangul count one word each; other runs of letters and digits count once (matches iA on 安.txt).
enum WordCount {
    private static let pattern = try! NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]|[\p{L}\p{N}'’_-]*[\p{L}\p{N}][\p{L}\p{N}'’_-]*"#)
    // Not counted by iA (measured): link destinations and ordered-list numbers. Code blocks are dropped separately.
    private static let ignored = try! NSRegularExpression(pattern: #"\]\([^)]*\)|^[ \t]*\d+(?:\.\d+)*\.[ \t]"#, options: [.anchorsMatchLines])
    private static let cjk = try! NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#)

    static func words(in text: String) -> Int {
        let code = NSMutableString(string: text)
        for block in Markdown.codeBlocks(in: text).reversed() { code.replaceCharacters(in: block, with: "\n") }
        let text = ignored.stringByReplacingMatches(in: code as String, range: NSRange(location: 0, length: code.length), withTemplate: " ")
        var n = 0
        let ns = text as NSString
        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            // A Latin run that swallowed CJK (\p{L} includes Han) is split: count its CJK characters, plus 1 per non-CJK piece.
            let s = ns.substring(with: match.range)
            let han = cjk.numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
            if han == 0 { n += 1; return }
            let pieces = cjk.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
                .split(separator: " ").count
            n += han + pieces
        }
        return n
    }
}
