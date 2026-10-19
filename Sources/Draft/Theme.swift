import AppKit

// Values extracted from iA Writer 8.0.6; see docs/measurements.md.
enum Theme {
    // iA's colours (system appearance) unless a Draft palette is chosen; see Palettes.swift.
    // Built the way iA builds them (gray color space, blends); the sRGB hex equivalents render differently.
    static let background = themed({ $0.isDark
        ? NSColor.black.blended(withFraction: 0.08, of: .white)!
        : NSColor.white.blended(withFraction: 0.04, of: .black)! }) { $0.bg }
    static let text = themed({ NSColor(white: $0.isDark ? 0.80 : 0.10, alpha: 1) }) { $0.text }
    // iA's rgb(...) colours are calibrated (Generic RGB) components, see docs/measurements.md §5.
    static let syntax = calibrated(light: (0.71, 0.70, 0.69), dark: (0.48, 0.48, 0.47)) { $0.syntax }
    static let url = calibrated(light: (0.84, 0.83, 0.82), dark: (0.33, 0.33, 0.32)) { $0.url }
    static let focusDim = calibrated(light: (0.78, 0.77, 0.76), dark: (0.44, 0.44, 0.44)) { $0.dim }
    static let focusDimSyntax = calibrated(light: (0.88, 0.87, 0.86), dark: (0.24, 0.24, 0.24)) { $0.dimSyntax }
    static let codeBackground = themed({ $0.isDark ? NSColor(white: 0.96, alpha: 0.05) : NSColor(white: 0.14, alpha: 0.045) }) { $0.codeBackground }
    static let hashtag = themed({ _ in NSColor(white: 0.55, alpha: 1) }) { $0.hashtag }

    // ==Highlight== in the style chosen in Settings (iA default Green).
    static let highlightBackground = NSColor(name: nil) {
        let h = Settings.highlight
        return h.base.withAlphaComponent($0.isDark ? h.backgroundAlpha.dark : h.backgroundAlpha.light)
    }
    static let highlightUnderline = NSColor(name: nil) { Settings.highlight.base.withAlphaComponent($0.isDark ? 0.75 : 1) }
    static let highlightText = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0.8, alpha: 1).blended(withFraction: 0.3, of: Settings.highlight.base)! : NSColor(white: 0.1, alpha: 1)
    }

    // Syntax Highlight, iA's Generic RGB values converted to sRGB.
    static let partOfSpeech: [(PartOfSpeech, NSColor)] = [
        (.adjective, dynamic(light: 0xA66501, dark: 0xC1944E)),
        (.verb, dynamic(light: 0x3476B9, dark: 0x7B9FC2)),
        (.noun, dynamic(light: 0xCB4819, dark: 0xD98567)),
        (.adverb, dynamic(light: 0xB24FA3, dark: 0xBA8DB3)),
        (.conjunction, dynamic(light: 0x3F831E, dark: 0x82A56F)),
    ]
    static var caret: NSColor { Settings.caretColor }
    static var selection: NSColor { caret.withAlphaComponent(0.25) }
    static var markedUnderline: NSColor { caret.withAlphaComponent(0.5) }

    private static func themed(_ ia: @escaping (NSAppearance) -> NSColor, _ palette: @escaping (Palette) -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in Palette.current.map(palette) ?? ia(appearance) }
    }

    private static func calibrated(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat),
                                   _ palette: @escaping (Palette) -> NSColor) -> NSColor {
        themed({ appearance in
            let c = appearance.isDark ? dark : light
            return NSColor(calibratedRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }, palette)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            rgb(appearance.isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

// The editor's type (typeface, size and line length from Settings), laid out for a given viewport width.
struct Typography {
    enum SizeClass { case compact, regular, wide }

    let fontSize: CGFloat
    let font: NSFont
    let boldFont: NSFont
    let italicFont: NSFont
    // Full-width punctuation. Font fallback would follow the neighbouring Han run, so it is set explicitly.
    let fullSpaceFont: NSFont?
    // Fallback drops the cascade's slant, so CJK inside *emphasis* gets this explicitly.
    let cjkItalicFont: NSFont?
    let lineHeight: CGFloat
    let baselineOffset: CGFloat
    let en: CGFloat
    let marginChars: CGFloat
    let containerWidth: CGFloat
    let insetWidth: CGFloat

    init(viewportWidth w: CGFloat, dark: Bool, retina: Bool,
         typeface face: Settings.Typeface = Settings.typeface, localFont: String? = Settings.localFont) {
        let size = Settings.size
        // A font installed on the Mac takes the typeface's place; a family that's gone falls back to the typeface.
        let local = localFont.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size.points) }
        let sizeClass: SizeClass = w <= 440 ? .compact : w <= 1250 ? .regular : .wide
        let base = face.spacing
        let spacing: CGFloat = (sizeClass == .compact ? base.0 : sizeClass == .regular ? base.1 : base.2)
            + (sizeClass == .compact ? 0 : size.smallSpacing) + size.largeSpacing
        let weight: CGFloat = retina ? size.weight - 35 - (dark ? 20 : 0) : 400
        let regular = local.map { $0.isFixedPitch ? size.lineHeight : size.quattroLineHeight }
            ?? (face == .quattro ? size.quattroLineHeight : size.lineHeight)
        let percent: CGFloat = regular + [SizeClass.compact: -10, .regular: 0, .wide: 10][sizeClass]!
        let pt = size.points

        fontSize = pt
        if let local {
            let manager = NSFontManager.shared
            font = Typography.withCascade(local, cjk: "PingFangTC-Regular")
            boldFont = Typography.withCascade(manager.convert(local, toHaveTrait: .boldFontMask), cjk: "PingFangTC-Semibold")
            italicFont = Typography.withCascade(manager.convert(local, toHaveTrait: .italicFontMask), cjk: "PingFangTC-Regular")
        } else {
            font = Typography.face(face.regular, size: pt, weight: weight, spacing: spacing, cjk: "PingFangTC-Regular")
            boldFont = Typography.face(face.regular, size: pt, weight: 700, spacing: spacing, cjk: "PingFangTC-Semibold")
            italicFont = Typography.face(face.italic, size: pt, weight: weight, spacing: spacing, cjk: "PingFangTC-Regular")
        }
        // A local font with its own Han keeps its own punctuation too.
        fullSpaceFont = local.map { Typography.hasGlyph("中", in: $0) } == true ? nil : NSFont(name: "iAWriterFullSpaceTC-Regular", size: pt)
        // The font matrix carries the point size, so it is scaled by it.
        cjkItalicFont = NSFont(descriptor: NSFontDescriptor(fontAttributes: [
            .name: "PingFangTC-Regular",
            .matrix: AffineTransform(m11: pt, m12: 0, m21: tan(9.5 * .pi / 180) * pt, m22: pt, tX: 0, tY: 0)]), size: pt)
        lineHeight = pt * percent / 100
        en = Typography.advance(of: "N", in: font)

        // TextKit 1 puts the baseline at lineHeight − ceil(descent); iA centres the cap height instead.
        baselineOffset = (lineHeight - ceil(-font.descender)) - (lineHeight + font.capHeight) / 2

        // Port of -[IATypographyLayout initWithViewportWidth:…].
        let gutter = min(sizeClass == .compact ? (w > 390 ? 18 : 13) : 6, w)
        let available = ceil(max(w - 2 * gutter, 0))
        let fit = ceil(available / en)
        let maxMargin: CGFloat = sizeClass == .compact ? 1 : min(floor(fit / 9), 7)
        let preferred: CGFloat = sizeClass == .compact ? 0 : sizeClass == .wide ? 8 : w <= 512 ? 3 : w <= 768 ? 4 : 6
        let lineWidth = ceil(en * Settings.lineLength) + 10
        let side = max(gutter, floor(max((w - lineWidth - 2 * gutter) / 2, 0)))
        var m = min(preferred, maxMargin)
        while ceil(en * m) < side && m < maxMargin { m += 1 }
        let total = 2 * m * en + lineWidth
        insetWidth = max(gutter - m * en, max((w - total) / 2, 0))
        containerWidth = min(total, max(w - 2 * insetWidth, 0))
        marginChars = m
    }

    func caretWidth(forHeight h: CGFloat) -> CGFloat {
        h > 58 ? 5 : h > 40 ? 4 : h >= 20.05 ? 3 : 2
    }

    // iA's cascade: full-width punctuation from iA Writer FullSpace TC, Han from PingFang, then Duo.
    private static func face(_ name: String, size: CGFloat, weight: CGFloat, spacing: CGFloat, cjk: String) -> NSFont {
        let variation: [NSNumber: CGFloat] = [tag("wght"): weight, tag("SPCG"): spacing]
        let descriptor = NSFontDescriptor(fontAttributes: [.name: name, .variation: variation, .cascadeList: cascade(cjk: cjk)])
        return NSFont(descriptor: descriptor, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func withCascade(_ font: NSFont, cjk: String) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.addingAttributes([.cascadeList: cascade(cjk: cjk)]), size: font.pointSize) ?? font
    }

    private static func cascade(cjk: String) -> [NSFontDescriptor] {
        [NSFontDescriptor(fontAttributes: [.name: "iAWriterFullSpaceTC-Regular"]),
         NSFontDescriptor(fontAttributes: [.name: cjk]),
         NSFontDescriptor(fontAttributes: [.name: "iAWriterDuo-Regular"])]
    }

    private static func tag(_ s: String) -> NSNumber {
        NSNumber(value: s.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    private static func hasGlyph(_ character: Character, in font: NSFont) -> Bool {
        var glyph = CGGlyph()
        var unichar = character.utf16.first!
        return CTFontGetGlyphsForCharacters(font, &unichar, &glyph, 1)
    }

    private static func advance(of character: Character, in font: NSFont) -> CGFloat {
        var glyph = CGGlyph()
        var unichar = character.utf16.first!
        guard CTFontGetGlyphsForCharacters(font, &unichar, &glyph, 1) else { return 10 }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }
}
