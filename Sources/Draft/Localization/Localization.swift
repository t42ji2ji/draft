import Foundation

// UI language (Settings › Language). Code is written in English and `L("…")` looks the text up in the
// 繁體中文 tables. Switching is live: whatever shows text re-reads it on `L10n.didChange`.
enum L10n {
    static let didChange = Notification.Name("DraftLanguageDidChange")

    enum Language: Int, CaseIterable {
        case system, english, traditionalChinese
    }

    static var language: Language {
        get { Language(rawValue: UserDefaults.standard.integer(forKey: "Language")) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "Language")
            // What AppKit draws itself (save panels, the find bar, About) picks its language at launch only.
            if newValue == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([newValue == .english ? "en" : "zh-Hant"], forKey: "AppleLanguages") }
            isChinese = resolve()
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private(set) static var isChinese = resolve()

    private static func resolve() -> Bool {
        switch language {
        case .english: return false
        case .traditionalChinese: return true
        case .system:
            // The global domain, not Locale.preferredLanguages: our own AppleLanguages override would shadow it.
            let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            let first = system?.first ?? "en"
            return ["zh-Hant", "zh-TW", "zh-HK", "zh-MO"].contains { first.hasPrefix($0) }
        }
    }

    static let traditionalChinese: [String: String] = [menu, settings, library, preview, assistant]
        .reduce(into: [:]) { $0.merge($1) { first, _ in first } }
}

// "Context|Text" keys tell apart words that translate differently in different places; English shows "Text".
func L(_ english: String) -> String {
    if L10n.isChinese, let zh = L10n.traditionalChinese[english] { return zh }
    return english.split(separator: "|", maxSplits: 1).last.map(String.init) ?? english
}
