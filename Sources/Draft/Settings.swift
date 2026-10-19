import AppKit

// User settings (Settings window, ⌘+ / ⌘−). Values and tables are iA Writer 8's, from
// TypographyKit.framework/Resources/{Mono,Duo,Quattro}.plist (docs/measurements.md §2).
enum Settings {
    static let didChange = Notification.Name("DraftSettingsDidChange")
    // Caret colour has its own notification: it only repaints, it doesn't restyle the document.
    static let caretColorDidChange = Notification.Name("DraftCaretColorDidChange")

    enum Typeface: Int, CaseIterable {
        case mono, duo, quattro
        var title: String { [L("Monospaced"), L("Duospaced"), "Quattro"][rawValue] }
        var regular: String { ["iAWriterMonoV-Regular", "iAWriterDuo-Regular", "iAWriterQuattroV-Regular"][rawValue] }
        var italic: String { ["iAWriterMonoV-Italic", "iAWriterDuo-Italic", "iAWriterQuattroV-Italic"][rawValue] }
        // SPCG base per size class (compact, regular, wide).
        var spacing: (CGFloat, CGFloat, CGFloat) { self == .quattro ? (0, 1, 2) : (10, 15, 20) }
    }

    struct Size {
        let name: String
        let points: CGFloat
        let lineHeight: CGFloat         // Regular class, Mono/Duo; Compact −10, ≥Wide +10
        let quattroLineHeight: CGFloat  // Regular class, Quattro
        let weight: CGFloat             // wght on Retina before the macOS/dark adjustments
        let smallSpacing: CGFloat       // SPCG added on ≥Regular
        let largeSpacing: CGFloat       // SPCG added in every class
    }

    // L's line heights are not in the plists' usual shape; 175 (measurements.md) and 164 (between M and XL) are inferred.
    static let sizes: [Size] = [
        Size(name: "4XS", points: 11, lineHeight: 180, quattroLineHeight: 170, weight: 490, smallSpacing: 22, largeSpacing: 0),
        Size(name: "3XS", points: 12, lineHeight: 179, quattroLineHeight: 169, weight: 482, smallSpacing: 18, largeSpacing: 0),
        Size(name: "2XS", points: 13, lineHeight: 179, quattroLineHeight: 168, weight: 475, smallSpacing: 14, largeSpacing: 0),
        Size(name: "XS", points: 14, lineHeight: 178, quattroLineHeight: 167, weight: 470, smallSpacing: 8, largeSpacing: 0),
        Size(name: "S", points: 15, lineHeight: 177, quattroLineHeight: 166, weight: 465, smallSpacing: 4, largeSpacing: 0),
        Size(name: "M", points: 16, lineHeight: 176, quattroLineHeight: 165, weight: 460, smallSpacing: 2, largeSpacing: 0),
        Size(name: "L", points: 18, lineHeight: 175, quattroLineHeight: 164, weight: 455, smallSpacing: 0, largeSpacing: 0),
        Size(name: "XL", points: 20, lineHeight: 173, quattroLineHeight: 163, weight: 450, smallSpacing: 0, largeSpacing: 0),
        Size(name: "2XL", points: 24, lineHeight: 169, quattroLineHeight: 159, weight: 445, smallSpacing: 0, largeSpacing: 0),
        Size(name: "3XL", points: 28, lineHeight: 165, quattroLineHeight: 155, weight: 440, smallSpacing: 0, largeSpacing: -1),
        Size(name: "4XL", points: 32, lineHeight: 161, quattroLineHeight: 151, weight: 435, smallSpacing: 0, largeSpacing: -2),
        Size(name: "5XL", points: 36, lineHeight: 157, quattroLineHeight: 147, weight: 430, smallSpacing: 0, largeSpacing: -3),
        Size(name: "6XL", points: 42, lineHeight: 151, quattroLineHeight: 142, weight: 425, smallSpacing: 0, largeSpacing: -4),
        Size(name: "7XL", points: 48, lineHeight: 145, quattroLineHeight: 137, weight: 425, smallSpacing: 0, largeSpacing: -5),
        Size(name: "8XL", points: 54, lineHeight: 139, quattroLineHeight: 132, weight: 425, smallSpacing: 0, largeSpacing: -6),
        Size(name: "9XL", points: 60, lineHeight: 133, quattroLineHeight: 127, weight: 425, smallSpacing: 0, largeSpacing: -7),
        Size(name: "10XL", points: 72, lineHeight: 128, quattroLineHeight: 123, weight: 425, smallSpacing: 0, largeSpacing: -8),
    ]
    static let defaultSizeIndex = 5   // M

    static let lineLengths: [CGFloat] = [64, 72, 80]

    // iA's highlight styles: P3 base colour and background alpha (light, dark).
    enum Highlight: Int, CaseIterable {
        case yellow, orange, pink, purple, blue, green
        var title: String { [L("Yellow"), L("Orange"), L("Pink"), L("Purple"), L("Blue"), L("Green")][rawValue] }
        var cssClass: String { ["yellow", "orange", "pink", "purple", "blue", "green"][rawValue] + "-mark" }
        var base: NSColor {
            switch self {
            case .yellow: NSColor(displayP3Red: 1, green: 0.85, blue: 0, alpha: 1)
            case .orange: NSColor(displayP3Red: 1, green: 0.5, blue: 0.25, alpha: 1)
            case .pink: NSColor(displayP3Red: 0.95, green: 0, blue: 0.7, alpha: 1)
            case .purple: NSColor(displayP3Red: 0.5, green: 0, blue: 0.95, alpha: 1)
            case .blue: NSColor(displayP3Red: 0, green: 0.75, blue: 1, alpha: 1)
            case .green: NSColor(displayP3Red: 0.6, green: 0.9, blue: 0, alpha: 1)
            }
        }
        var backgroundAlpha: (light: CGFloat, dark: CGFloat) {
            [(0.35, 0.175), (0.30, 0.175), (0.20, 0.225), (0.20, 0.30), (0.20, 0.175), (0.35, 0.175)][rawValue]
        }
    }

    // How *emphasis* shows on CJK text: dots under each character (着重号, default) or a 9.5° slant.
    enum CJKEmphasis: Int, CaseIterable {
        case marks, italic
        var title: String { [L("Emphasis Mark"), L("Italic")][rawValue] }
    }

    private static let defaults = UserDefaults.standard

    static var typeface: Typeface { Typeface(rawValue: defaults.integer(forKey: "Typeface")) ?? .mono }
    // A font family installed on the Mac, used instead of the typeface; nil for the typeface.
    static var localFont: String? { defaults.string(forKey: "LocalFont") }
    static func setFont(_ typeface: Typeface, local: String? = nil) {
        defaults.set(typeface.rawValue, forKey: "Typeface")
        defaults.set(local, forKey: "LocalFont")
        changed()
    }
    static var sizeIndex: Int {
        get { (defaults.object(forKey: "ContentSize") as? Int).map { min(max($0, 0), sizes.count - 1) } ?? defaultSizeIndex }
        set { defaults.set(min(max(newValue, 0), sizes.count - 1), forKey: "ContentSize"); changed() }
    }
    static var size: Size { sizes[sizeIndex] }
    static var lineLength: CGFloat {
        get { (defaults.object(forKey: "LineLength") as? Double).map { CGFloat($0) }.flatMap { lineLengths.contains($0) ? $0 : nil } ?? 64 }
        set { defaults.set(Double(newValue), forKey: "LineLength"); changed() }
    }
    static var highlight: Highlight {
        get { (defaults.object(forKey: "HighlightStyle") as? Int).flatMap(Highlight.init) ?? .green }
        set { defaults.set(newValue.rawValue, forKey: "HighlightStyle"); changed() }
    }
    static var cjkEmphasis: CJKEmphasis {
        get { CJKEmphasis(rawValue: defaults.integer(forKey: "CJKEmphasis")) ?? .marks }
        set { defaults.set(newValue.rawValue, forKey: "CJKEmphasis"); changed() }
    }

    // "ia" is iA's colours following the system appearance; otherwise a Palette id.
    static var paletteID: String {
        get { defaults.string(forKey: "Palette") ?? "ia" }
        set { defaults.set(newValue, forKey: "Palette"); changed() }
    }
    static var paper: Paper {
        get { Paper(rawValue: defaults.integer(forKey: "Paper")) ?? .none }
        set { defaults.set(newValue.rawValue, forKey: "Paper"); changed() }
    }
    // How strongly the paper pattern is drawn, 0.15–1 (Draft addition). Only redraws: dragging the slider shouldn't
    // re-style the whole document the way `didChange` does.
    static let paperOpacityDidChange = Notification.Name("DraftPaperOpacityDidChange")
    static var paperOpacity: Double {
        get { defaults.object(forKey: "PaperOpacity") as? Double ?? 1 }
        set { defaults.set(min(max(newValue, 0.15), 1), forKey: "PaperOpacity"); NotificationCenter.default.post(name: paperOpacityDidChange, object: nil) }
    }

    // iA's writerBlue. The selection is the caret colour at 25 % (docs/measurements.md §6).
    static let iaCaretColor = NSColor(displayP3Red: 0, green: 0.75, blue: 1, alpha: 1)
    // nil follows the palette.
    static var customCaretColor: NSColor? {
        get { defaults.data(forKey: "CaretColor").flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: $0) } }
        set {
            defaults.set(newValue.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }, forKey: "CaretColor")
            NotificationCenter.default.post(name: caretColorDidChange, object: nil)
        }
    }
    static var caretColor: NSColor { customCaretColor ?? Palette.current?.caret ?? iaCaretColor }

    private static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }
}
