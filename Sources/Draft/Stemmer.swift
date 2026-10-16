// Snowball English (Porter2) stemmer, for iA's stemmed Style Check rules (`s` modifier).
// Follows snowballstem/snowball algorithms/english.sbl (the 3.x version: `inter`/`past` prefixes, `ogist`,
// `-ing` exceptions inside Step 1b). Input is one lower-case word as UTF-16 code units;
// non-ASCII letters count as consonants.
enum Stemmer {
    static func stem(_ word: [UInt16]) -> [UInt16] {
        var english = English(word)
        return english.stem()
    }

    static func stem(_ word: String) -> String {
        String(decoding: stem(Array(word.utf16)), as: UTF16.self)
    }
}

private func u(_ s: String) -> [UInt16] { Array(s.utf16) }

private struct English {
    var w: [UInt16]
    var p1 = 0, p2 = 0

    init(_ word: [UInt16]) { w = word }

    private static let Y: UInt16 = 89, y: UInt16 = 121, e: UInt16 = 101, i: UInt16 = 105, apostrophe: UInt16 = 39

    private static let exception1: [[UInt16]: [UInt16]] = Dictionary(uniqueKeysWithValues: [
        ("skis", "ski"), ("skies", "sky"), ("idly", "idl"), ("gently", "gentl"), ("ugly", "ugli"),
        ("early", "earli"), ("only", "onli"), ("singly", "singl"), ("sky", "sky"), ("news", "news"),
        ("howe", "howe"), ("atlas", "atlas"), ("cosmos", "cosmos"), ("bias", "bias"), ("andes", "andes"),
    ].map { (u($0.0), u($0.1)) })
    private static let prefixes = ["gener", "commun", "arsen", "past", "univers", "later", "emerg", "organ", "inter"].map(u)
    private static let past = u("past")

    private static func isVowel(_ c: UInt16) -> Bool { c == 97 || c == 101 || c == 105 || c == 111 || c == 117 || c == 121 }
    private func vowel(_ k: Int) -> Bool { English.isVowel(w[k]) }

    private func ends(_ suffix: [UInt16], at end: Int? = nil) -> Bool {
        let end = end ?? w.count
        return suffix.count <= end && w[(end - suffix.count)..<end].elementsEqual(suffix)
    }

    // Longest entry of `list` (sorted longest first) that the word ends with.
    private func longest<T>(_ list: [([UInt16], T)]) -> ([UInt16], T)? { list.first { ends($0.0) } }

    private mutating func replace(_ count: Int, _ with: [UInt16]) {
        w.removeLast(count)
        w += with
    }

    private func hasVowel(before end: Int) -> Bool { (0..<max(0, end)).contains { vowel($0) } }

    // `shortv` over w[..<end].
    private func shortv(_ end: Int) -> Bool {
        if end >= 3, !vowel(end - 3), vowel(end - 2), !vowel(end - 1), ![119, 120, English.Y].contains(w[end - 1]) { return true }
        if end == 2, vowel(0), !vowel(1) { return true }
        return ends(English.past, at: end)
    }

    mutating func stem() -> [UInt16] {
        if let replacement = English.exception1[w] { return replacement }
        if w.count < 3 { return w }
        if w.first == English.apostrophe { w.removeFirst() }
        for k in w.indices where w[k] == English.y && (k == 0 || English.isVowel(w[k - 1])) { w[k] = English.Y }
        markRegions()
        step1a()
        step1b()
        step1c()
        step2()
        step3()
        step4()
        step5()
        for k in w.indices where w[k] == English.Y { w[k] = English.y }
        return w
    }

    private mutating func markRegions() {
        p1 = w.count
        p2 = w.count
        var start = 1
        if let prefix = English.prefixes.first(where: { w.starts(with: $0) }) {
            p1 = prefix.count
            start = p1 + 1
        } else {
            for k in 1..<max(1, w.count) where !vowel(k) && vowel(k - 1) { p1 = k + 1; start = p1 + 1; break }
            if p1 == w.count { return }
        }
        var k = start
        while k < w.count { if !vowel(k) && vowel(k - 1) && k - 1 >= p1 { p2 = k + 1; break }; k += 1 }
    }

    private func inR1(_ suffixLength: Int) -> Bool { w.count - suffixLength >= p1 }
    private func inR2(_ suffixLength: Int) -> Bool { w.count - suffixLength >= p2 }

    private static let step0 = ["'s'", "'s", "'"].map { (u($0), 0) }
    private static let step1a = ["sses", "ied", "ies", "us", "ss", "s"].map { (u($0), $0) }
    private mutating func step1a() {
        if let (s, _) = longest(English.step0) { w.removeLast(s.count) }
        guard let (_, s) = longest(English.step1a) else { return }
        switch s {
        case "sses": w.removeLast(2)
        case "ied", "ies": replace(3, w.count > 4 ? [English.i] : [English.i, English.e])
        case "s": if hasVowel(before: w.count - 2) { w.removeLast() }
        default: break
        }
    }

    private static let step1b = ["eedly", "ingly", "edly", "eed", "ing", "ed"].map { (u($0), $0) }
    private static let eedExceptions = ["proc", "exc", "succ"].map(u)
    private static let ingExceptions = ["inn", "out", "cann", "herr", "earr", "even"].map(u)
    private static let addE = ["at", "bl", "iz"].map(u)
    private static let ogi = u("ogi"), li = u("li"), ative = u("ative"), ion = u("ion")
    private static let doubles: [UInt16] = u("bdfgmnprt")
    private static let aeo: [UInt16] = u("aeo")
    private mutating func step1b() {
        guard let (sfx, s) = longest(English.step1b) else { return }
        let start = w.count - sfx.count
        switch s {
        case "eed", "eedly":
            guard start >= p1 else { return }
            if English.eedExceptions.contains(where: { $0.count == start && ends($0, at: start) }) { return }
            replace(sfx.count, [English.e, English.e])
            return
        case "ing":
            if start == 2, w[1] == English.y, !vowel(0) { replace(4, [English.i, English.e]); return }
            if English.ingExceptions.contains(where: { $0.count == start && ends($0, at: start) }) { return }
        default: break
        }
        guard hasVowel(before: start) else { return }
        w.removeLast(sfx.count)
        let n = w.count
        if English.addE.contains(where: { ends($0) }) {
            w.append(English.e)
        } else if n >= 2, w[n - 1] == w[n - 2], English.doubles.contains(w[n - 1]) {
            if !(n == 3 && English.aeo.contains(w[0])) { w.removeLast() }
        } else if n == p1, shortv(n) {
            w.append(English.e)
        }
    }

    private mutating func step1c() {
        let n = w.count
        guard n > 2, w[n - 1] == English.y || w[n - 1] == English.Y, !vowel(n - 2) else { return }
        w[n - 1] = English.i
    }

    private static let step2 = [
        ("tional", "tion"), ("enci", "ence"), ("anci", "ance"), ("abli", "able"), ("entli", "ent"),
        ("izer", "ize"), ("ization", "ize"), ("ational", "ate"), ("ation", "ate"), ("ator", "ate"),
        ("alism", "al"), ("aliti", "al"), ("alli", "al"), ("fulness", "ful"), ("ousli", "ous"),
        ("ousness", "ous"), ("iveness", "ive"), ("iviti", "ive"), ("biliti", "ble"), ("bli", "ble"),
        ("ogist", "og"), ("ogi", "og"), ("fulli", "ful"), ("lessli", "less"), ("li", ""),
    ].map { (u($0.0), u($0.1)) }.sorted { $0.0.count > $1.0.count }
    private static let validLI: [UInt16] = u("cdeghkmnrt")
    private mutating func step2() {
        guard let (s, r) = longest(English.step2), inR1(s.count) else { return }
        let before = w.count - s.count - 1
        if s == English.ogi && !(before >= 0 && w[before] == 108) { return }
        if s == English.li && !(before >= 0 && English.validLI.contains(w[before])) { return }
        replace(s.count, r)
    }

    private static let step3 = [
        ("tional", "tion"), ("ational", "ate"), ("alize", "al"), ("icate", "ic"), ("iciti", "ic"),
        ("ical", "ic"), ("ful", ""), ("ness", ""), ("ative", ""),
    ].map { (u($0.0), u($0.1)) }.sorted { $0.0.count > $1.0.count }
    private mutating func step3() {
        guard let (s, r) = longest(English.step3), inR1(s.count) else { return }
        if s == English.ative && !inR2(s.count) { return }
        replace(s.count, r)
    }

    private static let step4 = ["al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment",
                                "ent", "ism", "ate", "iti", "ous", "ive", "ize", "ion"]
        .map { (u($0), 0) }.sorted { $0.0.count > $1.0.count }
    private mutating func step4() {
        guard let (s, _) = longest(English.step4), inR2(s.count) else { return }
        if s == English.ion {
            let before = w.count - 4
            guard before >= 0, w[before] == 115 || w[before] == 116 else { return }
        }
        w.removeLast(s.count)
    }

    private mutating func step5() {
        guard let last = w.last else { return }
        if last == English.e {
            if inR2(1) || inR1(1) && !shortv(w.count - 1) { w.removeLast() }
        } else if last == 108, inR2(1), w.count >= 2, w[w.count - 2] == 108 {
            w.removeLast()
        }
    }
}
