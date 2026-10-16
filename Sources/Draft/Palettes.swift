import AppKit

// Draft's own colour palettes (not iA's). Each fixes a background, text and caret colour; the greys for
// Markdown syntax, focus dimming, links and paper lines are blends of text into background, in sRGB.
struct Palette {
    let id: String
    let name: String   // English, or an L10n key; shown as `title`
    let bg: NSColor
    let text: NSColor
    let caret: NSColor
    let line: NSColor?   // paper lines, when the blend isn't wanted

    var title: String { L(name) }
    var isDark: Bool { bg.brightnessComponent < 0.5 }

    // Fractions of the way from text to background (light, dark).
    var syntax: NSColor { blend(isDark ? 0.55 : 0.60) }
    var dim: NSColor { blend(isDark ? 0.70 : 0.72) }
    var dimSyntax: NSColor { blend(isDark ? 0.80 : 0.88) }
    var url: NSColor { blend(isDark ? 0.68 : 0.82) }
    var hashtag: NSColor { blend(0.5) }
    var paperLine: NSColor { line ?? blend(isDark ? 0.90 : 0.88) }
    var margin: NSColor { caret.usingColorSpace(.sRGB)!.blended(withFraction: 0.55, of: bg.usingColorSpace(.sRGB)!)! }
    var separator: NSColor { blend(isDark ? 0.91 : 0.93) }   // column dividers and bar separators, fainter than paper lines
    var chrome: NSColor { blend(isDark ? 0.94 : 0.95) }   // library tree and outline, a shade toward the text
    var selection: NSColor { blend(isDark ? 0.85 : 0.88) }   // selected row in the tree and outline
    var codeBackground: NSColor { text.withAlphaComponent(isDark ? 0.05 : 0.045) }

    private func blend(_ t: CGFloat) -> NSColor {
        text.usingColorSpace(.sRGB)!.blended(withFraction: t, of: bg.usingColorSpace(.sRGB)!)!
    }

    // nil is iA's colours, following the system appearance.
    static var current: Palette? { all.first { $0.id == Settings.paletteID } }

    static let all: [Palette] = [
        p("cream", "Cream", 0xF5F2E7, 0x2B2B27, 0xC2412D, line: 0xB3CBAC),
        p("ivory", "Ivory", 0xFBF8F1, 0x2E2826, 0x2F5D8A, line: 0xE8B5A8),
        p("moss", "Moss", 0xE4E8DC, 0x2C3529, 0xB5563A),
        p("fog", "Fog", 0xECECE8, 0x3A3A38, 0xD0533F),
        p("xuan", "Xuan", 0xF3EEE2, 0x1F1D1A, 0xA6372B),
        p("typewriter", "Typewriter", 0xF2EFE6, 0x1E1E1E, 0xB3261E),
        p("air-mail", "Air Mail", 0xF4F6FA, 0x22283A, 0xD0453A, line: 0xD3DCEB),
        p("graphite", "Pencil", 0xFFFFFF, 0x3C3C3C, 0x1A1A1A),
        p("mint", "Mint", 0xE9F2EC, 0x25352C, 0x2E8A5A),
        p("lamplight", "Lamplight", 0x211E1A, 0xDCD3C3, 0xE39A4C),
        p("ink", "Ink", 0x18202C, 0xD6DCE5, 0xE6BE6A),
        p("chalkboard", "Chalkboard", 0x1F2A24, 0xDCE3D9, 0xEAD47E),
        p("espresso", "Espresso", 0x2A211C, 0xE3D5C6, 0xD9A066),
        p("deep-sea", "Deep Sea", 0x0F1E24, 0xCFE0E3, 0x5FC3C9),
        p("burgundy", "Burgundy", 0x2A1A1E, 0xE6D3D6, 0xE07A8A),
        p("slate", "Graphite", 0x1C1C1E, 0xD4D4D2, 0xF2F2F0),
        p("dusk", "Dusk", 0x221E2E, 0xDAD5E6, 0xB39DF0),
        p("smoke", "Smoke", 0x2E2F31, 0xD8D8D4, 0xE8C26A),
    ]

    private static func p(_ id: String, _ name: String, _ bg: UInt32, _ text: UInt32, _ caret: UInt32, line: UInt32? = nil) -> Palette {
        Palette(id: id, name: name, bg: srgb(bg), text: srgb(text), caret: srgb(caret), line: line.map(srgb))
    }

    static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// Lines behind the text, one row per text line.
enum Paper: Int, CaseIterable {
    case none, ruled, notebook, squares, fine, dots, manuscript
    var title: String { [L("Paper|None"), L("Ruled"), L("Notebook"), L("Squares"), L("Fine Squares"), L("Dots"), L("Manuscript")][rawValue] }

    // Draws the pattern in `rect`. Rows start at `top` and are `pitch` tall; `left` is where the notebook margin goes.
    func draw(in rect: NSRect, top: CGFloat, pitch: CGFloat, left: CGFloat, line: NSColor, margin: NSColor) {
        guard self != .none, pitch > 0 else { return }
        let hair: CGFloat = 1
        let first = floor((rect.minY - top) / pitch) - 1
        let rows = stride(from: first, through: ceil((rect.maxY - top) / pitch), by: 1).map { top + $0 * pitch }
        line.setFill()
        switch self {
        case .none: break
        case .ruled, .notebook:
            for y in rows { NSRect(x: rect.minX, y: round(y + pitch) - hair, width: rect.width, height: hair).fill() }
            if self == .notebook {
                margin.setFill()
                NSRect(x: round(left), y: rect.minY, width: hair, height: rect.height).fill()
            }
        case .squares, .fine:
            let step = self == .squares ? pitch : pitch / 2
            var y = top + floor((rect.minY - top) / step) * step
            while y <= rect.maxY { NSRect(x: rect.minX, y: round(y + step) - hair, width: rect.width, height: hair).fill(); y += step }
            var x = floor(rect.minX / step) * step
            while x <= rect.maxX { NSRect(x: round(x + step) - hair, y: rect.minY, width: hair, height: rect.height).fill(); x += step }
        case .dots:
            let r = max(1.2, pitch / 22)
            for y in rows {
                var x = floor(rect.minX / pitch) * pitch
                while x <= rect.maxX + pitch {
                    NSBezierPath(ovalIn: NSRect(x: x - r, y: y + pitch - r, width: 2 * r, height: 2 * r)).fill()
                    x += pitch
                }
            }
        case .manuscript:
            // Square cells (22/28 of a row) with a gutter between rows, like 稿紙.
            let cell = round(pitch * 22 / 28)
            let gutter = (pitch - cell) / 2
            for y in rows {
                let band = NSRect(x: rect.minX, y: round(y + gutter), width: rect.width, height: cell)
                NSRect(x: band.minX, y: band.minY, width: band.width, height: hair).fill()
                NSRect(x: band.minX, y: band.maxY - hair, width: band.width, height: hair).fill()
                var x = floor(rect.minX / cell) * cell
                while x <= rect.maxX { NSRect(x: round(x), y: band.minY, width: hair, height: band.height).fill(); x += cell }
            }
        }
    }
}
