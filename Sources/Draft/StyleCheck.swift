import Foundation
import NaturalLanguage

// iA's Style Check. Rule lines are either iA's compiled form
//   {+|-};{modifiers};{mark ranges};{anchors};{text}
// or the source form used for custom patterns: `filler`, `context ~~redundant~~ context`, `-exception`.
//
// Chinese has no spaces, so zh source rules add word-level conditions on top (iA has no zh rules):
//   matches must start and end on word boundaries from the tokenizer (prefix `*` to allow any substring);
//   `@副詞` requires the matched word to have that lexical class; `>動詞` requires the next word to.
struct StyleCategory: OptionSet {
    let rawValue: Int
    static let fillers = StyleCategory(rawValue: 2)
    static let cliches = StyleCategory(rawValue: 4)
    static let redundancies = StyleCategory(rawValue: 8)
    static let all: StyleCategory = [.fillers, .cliches, .redundancies]
}

final class StyleCheck {
    private struct Rule {
        let exception: Bool
        let caseSensitive: Bool
        let languageVerified: Bool
        let language: String
        let category: StyleCategory
        let text: [UInt16]       // folded to lower-case ASCII unless caseSensitive
        let marks: [NSRange]
        let anchors: [(Int, Int)] // (6 = \b, 7 = \B, location)
        var wordAligned = false
        var tag: NLTag?
        var nextTag: NLTag?
    }

    static let shared = StyleCheck(directory: Bundle.main.resourceURL!.appendingPathComponent("StyleRules"))

    // Rules bucketed by `key`.
    private struct Table {
        var buckets: [UInt64: [Int]] = [:]
        var rules: [Rule] = []
    }

    private var plain = Table()
    // `s` rules: text is pre-stemmed and matched against the stemmed paragraph (see `stemmedCopy(of:)`).
    private var stemmed = Table()

    init(directory: URL) {
        for language in ["en", "zh"] {
            for (name, category) in [("fillers", StyleCategory.fillers), ("cliches", .cliches), ("redundancies", .redundancies)] {
                let url = directory.appendingPathComponent("\(language)-\(name).txt")
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in contents.split(separator: "\n") where !line.hasPrefix("//") {
                    if let (rule, isStemmed) = parse(String(line), language: language, category: category) {
                        if isStemmed { add(rule, to: &stemmed) } else { add(rule, to: &plain) }
                    }
                }
            }
        }
    }

    private func parse(_ line: String, language: String, category: StyleCategory) -> (Rule, Bool)? {
        let fields = line.split(separator: ";", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        if fields.count == 5, fields[0] == "+" || fields[0] == "-" {
            let modifiers = fields[1]
            // `s`, plus the compiler leftovers `ss` and `(go(es)?|went)`, whose text is stemmed too.
            let isStemmed = modifiers.contains("s")
            let pairs = { (s: String) in s.split(separator: " ").compactMap { p -> (Int, Int)? in
                let n = p.split(separator: ",").compactMap { Int($0) }
                return n.count == 2 ? (n[0], n[1]) : nil } }
            let caseSensitive = modifiers.contains("-i")
            return (Rule(exception: fields[0] == "-", caseSensitive: caseSensitive && !isStemmed,
                         languageVerified: modifiers.contains("l"), language: language, category: category,
                         text: fold(fields[4], caseSensitive && !isStemmed),
                         marks: pairs(fields[2]).map { NSRange(location: $0.0, length: $0.1) },
                         anchors: pairs(fields[3])), isStemmed)
        }
        // Source form.
        var text = line.trimmingCharacters(in: .whitespaces)
        let exception = text.hasPrefix("-")
        if exception { text.removeFirst() }
        var tag: NLTag?, nextTag: NLTag?
        while let space = text.lastIndex(of: " "), "@>".contains(text[text.index(after: space)]), let condition = conditions[String(text[text.index(after: space)...].dropFirst())] {
            if text[text.index(after: space)] == "@" { tag = condition } else { nextTag = condition }
            text = String(text[..<space]).trimmingCharacters(in: .whitespaces)
        }
        let substring = text.hasPrefix("*")
        if substring { text.removeFirst() }
        var marks: [NSRange] = []
        var plain = ""
        for (i, part) in text.components(separatedBy: "~~").enumerated() {
            if i % 2 == 1 { marks.append(NSRange(location: plain.utf16.count, length: part.utf16.count)) }
            plain += part
        }
        guard !plain.isEmpty else { return nil }
        if marks.isEmpty { marks = [NSRange(location: 0, length: plain.utf16.count)] }
        var rule = Rule(exception: exception, caseSensitive: false, languageVerified: false, language: language,
                        category: category, text: fold(plain, false), marks: marks, anchors: [])
        rule.wordAligned = language == "zh" && !substring
        rule.tag = tag
        rule.nextTag = nextTag
        return (rule, false)
    }

    private let conditions: [String: NLTag] = ["形容詞": .adjective, "名詞": .noun, "副詞": .adverb, "動詞": .verb, "連接詞": .conjunction]

    private func fold(_ s: String, _ caseSensitive: Bool) -> [UInt16] {
        s.utf16.map { !caseSensitive && $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
    }

    // The first four code units of a rule, or a shorter rule's units tagged with its length.
    private func key(_ s: [UInt16], _ i: Int, _ n: Int) -> UInt64 {
        var k = n < 4 ? UInt64(n) : 0
        for j in i..<i + n { k = k << 16 | UInt64(s[j]) }
        return k
    }

    private func add(_ rule: Rule, to table: inout Table) {
        guard !rule.text.isEmpty else { return }
        table.rules.append(rule)
        table.buckets[key(rule.text, 0, min(4, rule.text.count)), default: []].append(table.rules.count - 1)
    }

    // Struck ranges in one paragraph. `excluded` ranges (code, URLs) never match.
    func check(_ paragraph: String, categories: StyleCategory, language: String?, excluded: [NSRange],
               tokens: [(NSRange, NLTag?)]) -> [NSRange] {
        let raw = Array(paragraph.utf16)
        let folded = raw.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        var hits: [(NSRange, [NSRange])] = []
        var exceptions: [NSRange] = []

        var starts: [Int: NLTag?]?
        var ends: Set<Int> = []
        scan(plain, raw: raw, folded: folded, categories: categories, language: language) { rule, i in
            if rule.wordAligned || rule.tag != nil || rule.nextTag != nil, starts == nil {
                starts = Dictionary(tokens.map { ($0.0.location, $0.1) }, uniquingKeysWith: { a, _ in a })
                ends = Set(tokens.map { NSMaxRange($0.0) })
            }
            let end = i + rule.text.count
            if rule.wordAligned && (starts?.index(forKey: i) == nil || !ends.contains(end)) { return }
            if let tag = rule.tag, (starts?[i] ?? nil) != tag { return }
            if let tag = rule.nextTag, (starts?[end] ?? nil) != tag { return }
            let range = NSRange(location: i, length: rule.text.count)
            if rule.exception { exceptions.append(range) } else {
                hits.append((range, rule.marks.map { NSRange(location: i + $0.location, length: $0.length) }))
            }
        }

        if !stemmed.rules.isEmpty {
            let (text, startOf, endOf) = stemmedCopy(of: folded)
            let back = { (r: NSRange) in NSRange(location: startOf[r.location],
                                                 length: endOf[NSMaxRange(r)] - startOf[r.location]) }
            scan(stemmed, raw: text, folded: text, categories: categories, language: language) { rule, i in
                let range = back(NSRange(location: i, length: rule.text.count))
                if rule.exception { exceptions.append(range) } else {
                    hits.append((range, rule.marks.map { back(NSRange(location: i + $0.location, length: $0.length)) }))
                }
            }
        }

        let blocked = exceptions + excluded
        let marks = hits.filter { hit in !blocked.contains { NSIntersectionRange($0, hit.0).length > 0 } }
            .flatMap(\.1).sorted { $0.location < $1.location }
        return join(marks, in: raw)
    }

    // Calls `found` for every rule of `table` whose text (and anchors, category, language) match at an offset.
    private func scan(_ table: Table, raw: [UInt16], folded: [UInt16], categories: StyleCategory, language: String?,
                      found: (Rule, Int) -> Void) {
        for i in folded.indices {
            for n in 1...min(4, folded.count - i) {
                guard let candidates = table.buckets[key(folded, i, n)] else { continue }
                for index in candidates {
                    let rule = table.rules[index]
                    guard rule.category.isSubset(of: categories) || rule.exception,
                          matches(rule, at: i, raw: raw, folded: folded) else { continue }
                    if rule.languageVerified, let language, !language.hasPrefix(rule.language) { continue }
                    found(rule, i)
                }
            }
        }
    }

    // The folded paragraph with every word replaced by its Porter2 stem; everything else is copied as is.
    // A word is a run of letters and digits, with `'` or `’` allowed between letters ("they'll"); hyphens
    // and leading apostrophes separate, as the stemmed rule texts show (`co-oper`, `ralli 'round`).
    // startOf[j] / endOf[j] give the paragraph offset of a range starting / ending at stemmed offset j.
    // Inside a word, offset k maps to the word's k-th unit (clamped), so a mark covering part of a stem
    // (`over` in `overexagger`) covers the same prefix of the word; a range ending at a stem's end ends at
    // the word's end, so `advanc` strikes all of "advancing".
    private func stemmedCopy(of folded: [UInt16]) -> ([UInt16], [Int], [Int]) {
        var text: [UInt16] = [], startOf: [Int] = [], endOf: [Int] = [0]
        text.reserveCapacity(folded.count)
        startOf.reserveCapacity(folded.count + 1)
        endOf.reserveCapacity(folded.count + 1)
        var i = 0
        while i < folded.count {
            guard isWord(folded, i, underscore: false) else {
                text.append(folded[i]); startOf.append(i); endOf.append(i + 1)
                i += 1
                continue
            }
            var j = i + 1
            while j < folded.count, isWord(folded, j, underscore: false)
                    || (folded[j] == 39 || folded[j] == 0x2019) && j + 1 < folded.count && isWord(folded, j + 1, underscore: false) {
                j += 1
            }
            let stem = Stemmer.stem(Array(folded[i..<j]))
            for k in stem.indices {
                startOf.append(i + min(k, j - i - 1))
                endOf.append(k == stem.count - 1 ? j : i + min(k + 1, j - i))
            }
            text += stem
            i = j
        }
        startOf.append(folded.count)
        return (text, startOf, endOf)
    }

    private func matches(_ rule: Rule, at i: Int, raw: [UInt16], folded: [UInt16]) -> Bool {
        let source = rule.caseSensitive ? raw : folded
        guard i + rule.text.count <= source.count else { return false }
        for k in rule.text.indices where source[i + k] != rule.text[k] { return false }
        for (type, location) in rule.anchors {
            let p = i + location
            let boundary = isWord(raw, p - 1) != isWord(raw, p)
            if type == 6 && !boundary || type == 7 && boundary { return false }
        }
        return true
    }

    private func isWord(_ s: [UInt16], _ i: Int, underscore: Bool = true) -> Bool {
        guard i >= 0, i < s.count else { return false }
        let c = s[i]
        if c < 128 { return c >= 97 && c <= 122 || c >= 65 && c <= 90 || c >= 48 && c <= 57 || underscore && c == 95 }
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    // Merge marks separated only by whitespace, ',' or '-' into one struck run, as iA does.
    private func join(_ marks: [NSRange], in s: [UInt16]) -> [NSRange] {
        var result: [NSRange] = []
        for mark in marks {
            if let last = result.last {
                let gap = NSMaxRange(last)..<max(NSMaxRange(last), mark.location)
                if mark.location <= NSMaxRange(last) || gap.allSatisfy({ [32, 9, 44, 45].contains(s[$0]) }) {
                    result[result.count - 1] = NSUnionRange(last, mark)
                    continue
                }
            }
            result.append(mark)
        }
        return result
    }
}
