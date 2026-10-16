import AppKit

// Draws iA's backgrounds: inline code, code blocks and ==highlight== (docs/markdown-styling.md).
// Geometry is iA's at content size M (28.16 pt lines), scaled with the line height for other sizes.
final class EditorLayoutManager: NSLayoutManager {
    var inlineCode: [NSRange] = []
    var highlights: [NSRange] = []
    var codeBlocks: [NSRange] = []
    var emphasisMarks: [NSRange] = []   // CJK characters inside *emphasis*, each gets a dot below
    // A heading's "###" hidden off the caret's line; "H3" is drawn in its place, ending where the marks end.
    struct HeadingLabel {
        let range: NSRange   // the # characters
        let level: Int
        let color: NSColor
    }
    var headingLabels: [HeadingLabel] = []
    var columnInset: CGFloat = 0   // margin columns inside the container (E × marginChars)

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        Theme.codeBackground.setFill()
        for block in codeBlocks where NSIntersectionRange(block, visible).length > 0 {
            var rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: block, actualCharacterRange: nil), in: container)
            rect.origin.x = columnInset
            rect.size.width = container.size.width - 2 * columnInset
            NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y).integral, xRadius: 3, yRadius: 3).fill()
        }

        for span in inlineCode where NSIntersectionRange(span, visible).length > 0 {
            for rect in segments(of: span, in: container, origin: origin) {
                let height = rect.height * 23.92 / 28.16
                let box = NSRect(x: rect.minX - 1, y: rect.minY + (rect.height - height) / 2 - 0.04, width: rect.width + 2, height: height)
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            }
        }

        for span in highlights where NSIntersectionRange(span, visible).length > 0 {
            for rect in segments(of: span, in: container, origin: origin) {
                Theme.highlightBackground.setFill()
                let inset = rect.height * 1.12 / 28.16
                NSRect(x: rect.minX, y: rect.minY + inset, width: rect.width, height: rect.height - 2 * inset).fill()
                Theme.highlightUnderline.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - 1.84, width: rect.width, height: 1.84), xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    // One rect per line fragment the span crosses, full line height, in view coordinates.
    private func segments(of span: NSRange, in container: NSTextContainer, origin: NSPoint) -> [NSRect] {
        var rects: [NSRect] = []
        let glyphs = glyphRange(forCharacterRange: span, actualCharacterRange: nil)
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(glyphs, lineGlyphs)
            guard part.length > 0 else { return }
            var rect = self.boundingRect(forGlyphRange: part, in: container)
            rect.origin.y = fragment.minY
            rect.size.height = fragment.height
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }

    // 着重号: a dot centred under each marked character, in that character's current colour; and the heading labels.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first, let storage = textStorage else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for label in headingLabels where NSIntersectionRange(label.range, visible).length > 0 {
            let glyphs = glyphRange(forCharacterRange: label.range, actualCharacterRange: nil)
            let box = boundingRect(forGlyphRange: glyphs, in: container)
            let size = (storage.attribute(.font, at: label.range.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 16
            let font = NSFont.systemFont(ofSize: round(size * 0.7), weight: .semibold)
            let text = NSAttributedString(string: "H\(label.level)", attributes: [.font: font, .foregroundColor: label.color])
            let baseline = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY + location(forGlyphAt: glyphs.location).y
            text.draw(at: NSPoint(x: origin.x + box.maxX - text.size().width, y: origin.y + baseline - font.ascender))
        }
        for range in emphasisMarks where NSIntersectionRange(range, visible).length > 0 {
            for i in range.location..<NSMaxRange(range) {
                let glyph = glyphIndexForCharacter(at: i)
                let font = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont
                let size = font?.pointSize ?? 16
                let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let box = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                let baseline = line.minY + location(forGlyphAt: glyph).y
                let diameter = size * 0.16
                let dot = NSRect(x: box.midX - diameter / 2, y: baseline + size * 0.24, width: diameter, height: diameter)
                let color = temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) as? NSColor
                    ?? storage.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor ?? Theme.text
                color.setFill()
                NSBezierPath(ovalIn: dot.offsetBy(dx: origin.x, dy: origin.y)).fill()
            }
        }
    }
}
