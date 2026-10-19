import Foundation

// Inline Markdown as iA's editor shows it (docs/markdown-styling.md). Most markers keep the text colour;
// only link/footnote/reference punctuation, escapes, comments and HTML go grey.
enum Markdown {
    enum Kind { case syntax, url, autolink, code, heading, strong, emphasis, strike, highlight, hashtag, taskDone }

    private static let patterns: [(NSRegularExpression, [(Int, Kind)])] = [
        (#"^#{1,6}[ \t]+.*"#, [(0, .heading)]),
        (#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, [(0, .strong)]),
        // CommonMark: `*` may sit inside a word (needed for CJK, which has no spaces); `_` may not.
        (#"(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)"#, [(0, .emphasis)]),
        (#"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#, [(0, .emphasis)]),
        (#"~~(?=\S)(.+?)(?<=\S)~~"#, [(0, .strike)]),
        (#"==(?=\S)(.+?)(?<=\S)=="#, [(0, .highlight)]),
        (#"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)"#, [(0, .code)]),        // CommonMark: backtick runs pair whole
        (#"(!?\[)(?!\^)([^\]]*)(\]\()([^)\s]*)((?:[ \t]+"[^"]*")?\))"#, [(1, .syntax), (3, .syntax), (4, .url), (5, .syntax)]),
        (#"\[\^[^\]\s]+\](:)?"#, [(0, .syntax)]),                                   // footnote reference / definition marker
        (#"^[ ]{0,3}\[[^\]\^#][^\]]*\]:[ \t]*(\S+).*"#, [(0, .syntax), (1, .url)]),  // reference definition
        (#"(\[\[)([^\]|]+)(\|[^\]]*)?(\]\])"#, [(1, .syntax), (2, .autolink), (4, .syntax)]),
        (#"(<)(https?://[^>\s]+)(>)"#, [(1, .syntax), (2, .autolink), (3, .syntax)]),
        (#"(?<![(<\w/])https?://[^\s)>\]]+"#, [(0, .autolink)]),
        (#"\\(?=[\\`*_{}\[\]()#+\-.!~=|<>])|\\$"#, [(0, .syntax)]),                  // escapes, hard break
        (#"^[ \t]*//.*"#, [(0, .syntax)]),                                           // comment line
        (#"</?[A-Za-z][^>\n]*>"#, [(0, .syntax)]),                                  // HTML
        (#"(?<![\p{L}\p{N}_#&/])#[\p{L}\p{N}_][\p{L}\p{N}_\-]*"#, [(0, .hashtag)]),
        (#"^[ \t]*(?:[-*+]|\d+\.)[ \t]+\[[xX]\][ \t].*"#, [(0, .taskDone)]),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.anchorsMatchLines]), $0.1) }

    // Spans excluded from syntax highlight and style check.
    static let unchecked: Set<Kind> = [.syntax, .url, .autolink, .code]

    private static let heading = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)
    // `---`, `* * *`, `___`: a rule, not a list item.
    private static let rule = try! NSRegularExpression(pattern: #"^[ ]{0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)

    static func isHorizontalRule(_ string: String, line: NSRange) -> Bool {
        rule.firstMatch(in: string, range: line) != nil
    }
    private static let block = try! NSRegularExpression(pattern: #"^[ \t]*(?:(?:[-*+]|\d+(?:\.\d+)*\.)[ \t]+(?:\[[ xX]\][ \t]+)?|(?:>[ \t]?)+)?"#)

    // Characters covered by iA Writer FullSpace TC.
    static let fullWidthPunctuation = try! NSRegularExpression(pattern: #"[\x{2026}\x{FF01}\x{FF02}\x{FF07}-\x{FF09}\x{FF0C}\x{FF0E}\x{FF0F}\x{FF1A}\x{FF1B}\x{FF1F}\x{FF3B}-\x{FF3D}\x{FF3F}\x{FF5B}\x{FF5D}]+"#)
    // Characters that take an emphasis mark (着重号/傍点): ideographs and kana/hangul, not punctuation.
    static let emphasisMarked = try! NSRegularExpression(pattern: #"[\p{Han}\p{Bopomofo}\p{Hiragana}\p{Katakana}\p{Hangul}]"#)
    static let cjk = try! NSRegularExpression(pattern: #"[\p{Han}\p{Bopomofo}\x{3000}-\x{303F}\x{FF00}-\x{FFEF}]+"#)

    static func spans(in string: String, range: NSRange) -> [(NSRange, Kind)] {
        var result: [(NSRange, Kind)] = []
        for (regex, groups) in patterns {
            regex.enumerateMatches(in: string, range: range) { match, _, _ in
                guard let match else { return }
                for (g, kind) in groups where match.range(at: g).location != NSNotFound && match.range(at: g).length > 0 {
                    result.append((match.range(at: g), kind))
                }
            }
        }
        return result
    }

    // Inline formatting whose markers can hide or be unwrapped: the marker length on each side, nil for other kinds.
    static func markerLength(of kind: Kind, span: NSRange, in string: NSString) -> Int? {
        switch kind {
        case .strong, .strike, .highlight: return 2
        case .emphasis: return 1
        case .code: return string.substring(with: span).prefix { $0 == "`" }.count
        default: return nil
        }
    }

    // Only heading marks hang into the left margin ("## ").
    static func hangingMarkerLength(in string: String, paragraph: NSRange) -> Int {
        heading.firstMatch(in: string, range: paragraph)?.range.length ?? 0
    }

    // Leading whitespace plus list/quote marker; wrapped lines align after it. Tabs count as `tabWidth` columns.
    static func blockMarkerColumns(in string: String, paragraph: NSRange, tabWidth: Int) -> Int {
        guard !isHorizontalRule(string, line: paragraph), let match = block.firstMatch(in: string, range: paragraph) else { return 0 }
        return (string as NSString).substring(with: match.range).reduce(0) { $0 + ($1 == "\t" ? tabWidth : 1) }
    }

    // Fenced (``` / ~~~; an unclosed fence runs to the end) and indented (4 spaces or a tab, after a blank line) code blocks.
    // Scans UTF-16 directly: this runs on every Enter, so it has to stay cheap on long documents.
    static func codeBlocks(in string: String) -> [NSRange] {
        let u = Array(string.utf16)
        let n = u.count
        var blocks: [NSRange] = []
        var fence: (char: UInt16, start: Int)?
        var indented: NSRange?
        var previousBlank = true
        var start = 0
        while start <= n {
            var end = start
            while end < n && u[end] != 10 { end += 1 }
            var lead = 0
            while start + lead < end && u[start + lead] == 32 { lead += 1 }
            let first = start + lead
            let isFence = { (c: UInt16) in lead <= 3 && first + 2 < end && u[first] == c && u[first + 1] == c && u[first + 2] == c }
            if let open = fence {
                if isFence(open.char) {
                    blocks.append(NSRange(location: open.start, length: end - open.start))
                    fence = nil
                }
            } else if let c: UInt16 = isFence(96) ? 96 : isFence(126) ? 126 : nil {
                if let block = indented { blocks.append(block); indented = nil }
                fence = (c, start)
                previousBlank = false
            } else {
                var blank = true
                for i in start..<end where u[i] != 32 && u[i] != 9 { blank = false; break }
                let isIndented = lead >= 4 || (start < end && u[start] == 9)
                if let block = indented {
                    if isIndented && !blank { indented = NSRange(location: block.location, length: end - block.location) }
                    else if !blank { blocks.append(block); indented = nil }
                } else if isIndented && !blank && previousBlank {
                    indented = NSRange(location: start, length: end - start)
                }
                previousBlank = blank
            }
            if end >= n { break }
            start = end + 1
        }
        if let block = indented { blocks.append(block) }
        // An unclosed fence already styles everything after it (Draft choice; iA waits for the closing fence).
        if let open = fence { blocks.append(NSRange(location: open.start, length: n - open.start)) }
        return blocks
    }
}
