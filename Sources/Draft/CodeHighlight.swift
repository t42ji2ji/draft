import Foundation

// Colours inside fenced code blocks (Draft addition, docs/markdown-styling.md): the fence lines go grey like other
// Markdown marks, and the body is tokenised by the language named after the opening fence. Unknown languages and
// indented blocks keep the text colour.
enum CodeHighlight {
    enum Kind { case fence, comment, string, number, keyword }

    // Spans in `block`, a whole code block as `Markdown.codeBlocks` finds it (no trailing newline).
    static func spans(in block: String) -> [(NSRange, Kind)] {
        let ns = block as NSString
        guard let open = opener.firstMatch(in: block, range: NSRange(location: 0, length: ns.length)) else { return [] }
        let firstBreak = ns.range(of: "\n").location
        let firstEnd = firstBreak == NSNotFound ? ns.length : firstBreak
        var result: [(NSRange, Kind)] = [(NSRange(location: 0, length: firstEnd), .fence)]
        var bodyEnd = ns.length
        // The closing fence: the same character, three or more, after at most three spaces. An unclosed fence has none.
        let lastBreak = ns.range(of: "\n", options: .backwards).location
        if lastBreak != NSNotFound {
            let last = ns.substring(from: lastBreak + 1)
            let marker = ns.substring(with: open.range(at: 1)).prefix(3)
            let lead = last.prefix { $0 == " " }.count
            if lead <= 3, last.dropFirst(lead).hasPrefix(marker) {
                result.append((NSRange(location: lastBreak + 1, length: ns.length - lastBreak - 1), .fence))
                bodyEnd = lastBreak
            }
        }
        let name = ns.substring(with: open.range(at: 2)).lowercased()
        guard let regex = languages[name], bodyEnd > firstEnd else { return result }
        let kinds: [Kind] = [.comment, .string, .number, .keyword]
        regex.enumerateMatches(in: block, range: NSRange(location: firstEnd, length: bodyEnd - firstEnd)) { match, _, _ in
            guard let match else { return }
            for (g, kind) in kinds.enumerated() where match.range(at: g + 1).location != NSNotFound {
                result.append((match.range(at: g + 1), kind))
            }
        }
        return result
    }

    // The body of a closed ```mermaid block; nil for anything else.
    static func mermaidSource(in block: String) -> String? {
        let ns = block as NSString
        guard let open = opener.firstMatch(in: block, range: NSRange(location: 0, length: ns.length)),
              ns.substring(with: open.range(at: 2)).lowercased() == "mermaid" else { return nil }
        let fences = spans(in: block).map(\.0)
        guard fences.count == 2 else { return nil }
        let start = NSMaxRange(fences[0]) + 1
        return ns.substring(with: NSRange(location: start, length: max(0, fences[1].location - 1 - start)))
    }

    private static let opener = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})[ \t]*([^\s`{]*)"#)

    private static let slash = #"//[^\n]*"#, block = #"/\*[\s\S]*?(?:\*/|\z)"#, hash = #"(?<!\S)#[^\n]*"#
    private static let dashes = #"--[^\n]*"#, markup = #"<!--[\s\S]*?(?:-->|\z)"#
    private static let double = #"\"(?:\\.|[^\"\\\n])*\"?"#, single = #"'(?:\\.|[^'\\\n])*'?"#
    private static let backtick = #"`(?:\\[\s\S]|[^`\\])*`?"#
    private static let tripleDouble = #"\"{3}[\s\S]*?(?:\"{3}|\z)"#, tripleSingle = #"'{3}[\s\S]*?(?:'{3}|\z)"#

    // One alternation per language: comment | string | number | keyword. The leftmost match wins, so keywords
    // inside strings and comments stay string or comment.
    private static func language(_ comments: [String], _ strings: [String], _ keywords: String, ignoringCase: Bool = false) -> NSRegularExpression {
        let either = { (parts: [String]) in parts.isEmpty ? "(?!)" : parts.joined(separator: "|") }
        let words = keywords.split(separator: " ").joined(separator: "|")
        let number = #"\b(?:0[xX][\da-fA-F_]+|0[bBoO][0-7_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
        let pattern = "(\(either(comments)))|(\(either(strings)))|(\(number))|(\(words.isEmpty ? "(?!)" : #"\b(?:"# + words + #")\b"#))"
        return try! NSRegularExpression(pattern: pattern, options: ignoringCase ? [.caseInsensitive] : [])
    }

    private static let languages: [String: NSRegularExpression] = {
        var table: [String: NSRegularExpression] = [:]
        func add(_ names: String, _ regex: NSRegularExpression) {
            for name in names.split(separator: " ") { table[String(name)] = regex }
        }
        add("swift", language([slash, block], [tripleDouble, double], """
            let var func if else guard return for in while repeat switch case default break continue fallthrough struct \
            class enum protocol extension import init deinit self Self super static private fileprivate internal public \
            open final override mutating throws throw rethrows try catch do defer as is nil true false where async await \
            some any lazy weak unowned inout typealias associatedtype subscript get set willSet didSet convenience required
            """))
        add("js javascript jsx mjs ts typescript tsx", language([slash, block], [double, single, backtick], """
            var let const function return if else for while do switch case default break continue new this class extends \
            super import export from as async await yield try catch finally throw typeof instanceof in of delete void \
            null undefined true false static get set interface type enum implements private public protected readonly \
            declare namespace keyof
            """))
        add("py python", language([hash], [tripleDouble, tripleSingle, double, single], """
            def class return if elif else for while in not and or is import from as with try except finally raise pass \
            break continue lambda yield global nonlocal assert del async await None True False self match case
            """))
        add("sh bash zsh shell console fish", language([hash], [double, single], """
            if then else elif fi for while until do done case esac in function return local export readonly exit source
            """))
        add("go golang", language([slash, block], [double, single, backtick], """
            func package import var const type struct interface map chan go defer return if else for range switch case \
            default break continue fallthrough select goto nil true false
            """))
        add("rs rust", language([slash, block], [double], """
            fn let mut const static struct enum trait impl pub use mod crate self Self super match if else loop while for \
            in return break continue as ref move async await dyn where unsafe extern type true false Some None Ok Err
            """))
        add("c h cpp c++ cc hpp objc objective-c java kt kotlin cs csharp dart scala php", language([slash, block], [tripleDouble, double, single], """
            if else for while do switch case default break continue return goto struct union enum typedef sizeof static \
            const extern void int char float double long short unsigned signed bool boolean true false null nullptr NULL \
            class public private protected virtual override new delete this namespace using template typename import \
            package interface extends implements final abstract try catch throw throws finally fun val var object when \
            is in as self nil let def function
            """))
        add("rb ruby", language([hash], [double, single], """
            def end class module if elsif else unless while until for in do return yield begin rescue ensure raise nil \
            true false self then case when require
            """))
        add("lua", language([dashes], [double, single], """
            local function end if then else elseif for in do while repeat until return nil true false and or not break
            """))
        add("sql mysql postgres postgresql sqlite", language([dashes, block], [single, double], """
            select from where insert into update delete set values create table drop alter index join left right inner \
            outer on and or not null is as group by order having limit offset distinct union all case when then else end \
            primary key references default returning with
            """, ignoringCase: true))
        add("json jsonc json5", language([slash, block], [double], "true false null"))
        add("yaml yml toml ini", language([hash], [double, single], "true false null yes no on off"))
        add("css scss less", language([block, slash], [double, single], ""))
        add("html xml svg plist vue", language([markup], [double], ""))
        return table
    }()
}
