import Foundation

// Port of iA Writer's +[IATextNormalization nameWithText:final:]; see docs/storage.md §3.3.
enum DocumentName {
    static let fallback = "Untitled"
    static let maxLength = 64

    struct Result: Equatable {
        var name: String
        var isFinal: Bool
    }

    static func derive(from text: String) -> Result {
        let ns = text as NSString
        var location = 0
        var lineIndex = 0
        var inMetadata = false
        while location < ns.length {
            var end = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let line = ns.substring(with: NSRange(location: location, length: contentsEnd - location))
            let terminated = end > contentsEnd
            defer { location = end; lineIndex += 1 }
            // Frontmatter (`---` … `---` at the top) is metadata, never a name.
            if lineIndex == 0 && line == "---" { inMetadata = true; continue }
            if inMetadata { if line == "---" || line == "..." { inMetadata = false }; continue }
            let candidate = sanitize(stripMarkdown(line))
            guard !candidate.isEmpty else { continue }
            let (name, cut) = shorten(candidate)
            return Result(name: name.isEmpty ? fallback : name, isFinal: terminated || cut)
        }
        return Result(name: fallback, isFinal: false)
    }

    // MARK: - Steps

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    // (pattern, template) applied in order.
    private static let markdown: [(NSRegularExpression, String)] = [
        (regex(#"<!--|-->"#), ""),                                              // HTML comment delimiters
        (regex(#"^\s*//\s?"#), ""),                                             // iA comment line
        (regex(#"^\s{0,3}#{1,6}(?=\s|$)"#), ""),                                // heading marker
        (regex(#"\s#+\s*$"#), ""),                                              // closing heading hashes
        (regex(#"^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#), ""),             // list marker (+ task box)
        (regex(#"!?\[([^\]]*)\]\([^)]*\)"#), "$1"),                             // link / image: keep the text
        (regex(#"!?\[([^\]]*)\]\[[^\]]*\]"#), "$1"),                            // reference link
        (regex(#"\[\^[^\]]*\]"#), ""),                                          // footnote reference
        (regex(#"\[\[([^\]]*)\]\]"#), "$1"),                                    // wikilink brackets
        (regex(#"<(https?://[^>\s]+)>"#), "$1"),                                // autolink brackets
        (regex(#"\bhttps?://"#), ""),                                           // autolink scheme
        (regex(#"</?[A-Za-z][^>]*>"#), ""),                                     // HTML tags
        (regex(#"(\*\*|__|~~|==)(?=\S)(.+?)(?<=\S)\1"#), "$2"),                 // strong, strike, highlight
        (regex(#"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)"#), "$1"),      // *emphasis*
        (regex(#"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#), "$1"),     // _emphasis_
        (regex(#"(`+)(.+?)\1"#), "$2"),                                         // code
        (regex(#"[\t ]{2,}"#), " "),
    ]

    static func stripMarkdown(_ line: String) -> String {
        var s = line
        for (re, template) in markdown {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "|: \t\u{3000}"))
    }

    private static let leadingDots = regex(#"^\.+"#)
    private static let dateSlash = regex(#"([0-9]+)/(?=[0-9])"#)
    private static let separators = regex(#"[:/ ]+"#)

    static func sanitize(_ input: String) -> String {
        var s = input as NSString
        if s.length > 255 { s = s.substring(to: s.rangeOfComposedCharacterSequence(at: 255).location) as NSString }
        var r = s as String
        r = leadingDots.stringByReplacingMatches(in: r, range: NSRange(location: 0, length: (r as NSString).length), withTemplate: "")
        r = dateSlash.stringByReplacingMatches(in: r, range: NSRange(location: 0, length: (r as NSString).length), withTemplate: "$1.")
        r = separators.stringByReplacingMatches(in: r, range: NSRange(location: 0, length: (r as NSString).length), withTemplate: " ")
        r = r.trimmingCharacters(in: CharacterSet(charactersIn: "\t \u{3000}"))
        return r.decomposedStringWithCompatibilityMapping
    }

    private static let trailingTrim: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        set.insert(charactersIn: " \u{3000}")
        set.remove(charactersIn: "()")
        return set
    }()

    private static func trimTrailing(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, trailingTrim.contains(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    // Sentence cut, then the 64-unit cap. Returns whether the cap cut text off.
    static func shorten(_ line: String) -> (String, Bool) {
        let ns = line as NSString
        var result: String?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.bySentences, .substringNotRequired]) { _, range, _, stop in
            let candidate = trimTrailing(ns.substring(to: NSMaxRange(range)))
            let units = candidate.utf16
            if units.count >= 5, let last = units.last, !(48...57).contains(last) {
                result = candidate
                stop.pointee = true
            }
        }
        var name = result ?? trimTrailing(line)
        if name.isEmpty { name = line }
        var cut = false
        let n = name as NSString
        if n.length > maxLength {
            cut = true
            var wordEnd = 0
            n.enumerateSubstrings(in: NSRange(location: 0, length: n.length), options: [.byWords, .localized, .substringNotRequired]) { _, range, _, stop in
                if NSMaxRange(range) <= maxLength { wordEnd = NSMaxRange(range) } else { stop.pointee = true }
            }
            if wordEnd == 0 { wordEnd = n.rangeOfComposedCharacterSequence(at: maxLength).location }
            name = (n.substring(to: wordEnd) as String).trimmingCharacters(in: CharacterSet(charactersIn: " \t\u{3000}"))
        }
        return (name.decomposedStringWithCompatibilityMapping, cut)
    }

    // MARK: - Renaming (docs/storage.md §3.4)

    // The existing extension stays unless the user typed a plain-text one; the stem is sanitised as in §3.3 step 3.
    static func renamedFileName(_ input: String, current: String) -> String? {
        var stem = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var ext = (current as NSString).pathExtension
        let typed = (stem as NSString).pathExtension
        if Library.textExtensions.contains(typed.lowercased()) {
            ext = typed
            stem = (stem as NSString).deletingPathExtension
        }
        stem = sanitize(stem)
        guard !stem.isEmpty else { return nil }
        return ext.isEmpty ? stem : stem + "." + ext
    }

    // MARK: - Collisions (docs/storage.md §3.5)

    private static let numbered = regex(#"^(.*?)(?: +([1-9][0-9]{0,2}))?$"#)

    private static func split(_ stem: String) -> (base: String, number: Int) {
        let ns = stem as NSString
        guard let m = numbered.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)) else { return (stem, 1) }
        let base = ns.substring(with: m.range(at: 1))
        let number = m.range(at: 2).location == NSNotFound ? 1 : Int(ns.substring(with: m.range(at: 2))) ?? 1
        return (base, number)
    }

    // `Name.txt`, then `Name 2.txt`, `Name 3.txt`…, matched case-insensitively against `existing` file names.
    static func uniqueFileName(stem: String, ext: String, existing: [String]) -> String {
        let base = split(stem).base.lowercased()
        var taken = Set<Int>()
        for file in existing {
            let f = file as NSString
            guard f.pathExtension.lowercased() == ext.lowercased() else { continue }
            let parts = split(f.deletingPathExtension)
            if parts.base.lowercased() == base { taken.insert(parts.number) }
        }
        if !taken.contains(1) && !existing.contains(where: { $0.lowercased() == "\(stem).\(ext)".lowercased() }) {
            return "\(stem).\(ext)"
        }
        let original = split(stem).base
        var n = 2
        while taken.contains(n) { n += 1 }
        return "\(original) \(n).\(ext)"
    }
}
