import Foundation

// Markdown → HTML body, shaped like iA Writer 8's preview output (docs/preview.md §3).
// iA renders with a modified MultiMarkdown 6 inside Kit.framework; the tag strings below are the ones
// found in that binary. List and block rules follow MultiMarkdown, not CommonMark: a nested list needs
// four spaces, and a list keeps its first marker type when later items switch between `-` and `1.`.
struct PreviewRenderer {
    /// Folder of the document; content blocks (`/image.png`) and relative images resolve against it.
    var baseURL: URL?
    /// Adds `data-line` (1-based source line) to top-level blocks, used for scroll sync. Off for export.
    var sourceLines = true
    /// Rewrites image sources against the folder they appear in (the preview maps them to its file scheme).
    var imageURL: ((String, URL?) -> String)?

    func render(_ source: String) -> String {
        var state = State(baseURL: baseURL, sourceLines: sourceLines)
        state.imageURL = imageURL
        return state.document(source)
    }
}

// MARK: - Document state

private struct Line {
    var text: String
    var number: Int
    var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }
    var indent: Int {
        var n = 0
        for c in text { if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break } }
        return n
    }
    func dropping(_ columns: Int) -> Line {
        var n = 0, idx = text.startIndex
        while idx < text.endIndex, n < columns {
            let c = text[idx]
            if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break }
            idx = text.index(after: idx)
        }
        return Line(text: String(text[idx...]), number: number)
    }
}

private struct Heading { var level: Int; var id: String; var html: String }

private struct State {
    let baseURL: URL?
    let sourceLines: Bool
    var references: [String: (url: String, title: String?)] = [:]
    var footnoteText: [String: [Line]] = [:]
    var footnoteOrder: [String] = []
    var inlineFootnotes: [String: String] = [:]
    var headings: [Heading] = []
    var usedIDs: Set<String> = []
    var depth = 0  // content-block transclusion depth
    var imageURL: ((String, URL?) -> String)?

    init(baseURL: URL?, sourceLines: Bool) {
        self.baseURL = baseURL
        self.sourceLines = sourceLines
    }

    mutating func document(_ source: String) -> String {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").enumerated().map { Line(text: $0.element, number: $0.offset + 1) }
        lines = stripFrontMatter(lines)
        lines = collectDefinitions(lines)
        var body = blocks(lines, topLevel: true)
        if body.contains(Self.tocMarker) { body = body.replacingOccurrences(of: Self.tocMarker, with: toc()) }
        body += footnotes()
        return body
    }

    // YAML front matter is not shown (inferred: iA hides it in the editor's preview).
    private func stripFrontMatter(_ lines: [Line]) -> [Line] {
        guard lines.first?.text == "---", let end = lines.dropFirst().firstIndex(where: { $0.text == "---" || $0.text == "..." }),
              lines[1..<end].allSatisfy({ $0.text.contains(":") || $0.text.hasPrefix(" ") || $0.text.hasPrefix("-") || $0.isBlank })
        else { return lines }
        return Array(lines[(end + 1)...])
    }

    // Link reference and footnote definitions are removed from the flow before block parsing.
    private mutating func collectDefinitions(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        var i = 0
        var inFence: String?
        while i < lines.count {
            let line = lines[i]
            let t = line.text.trimmingCharacters(in: .whitespaces)
            if let fence = inFence {
                if t.hasPrefix(fence) { inFence = nil }
                out.append(line); i += 1; continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence = String(t.prefix(3)); out.append(line); i += 1; continue }
            if line.indent < 4, let m = Rx.footnoteDef.firstMatch(line.text) {
                let id = m[1].lowercased()
                var body = [Line(text: m[2], number: line.number)]
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    if next.isBlank {
                        if i + 1 < lines.count, lines[i + 1].indent >= 4 { body.append(next); i += 1; continue }
                        break
                    }
                    if next.indent >= 4 { body.append(next.dropping(4)); i += 1; continue }
                    if Rx.footnoteDef.firstMatch(next.text) != nil || Rx.linkDef.firstMatch(next.text) != nil { break }
                    body.append(next); i += 1  // lazy continuation
                }
                footnoteText[id] = body
                continue
            }
            if line.indent < 4, let m = Rx.linkDef.firstMatch(line.text) {
                var url = m[2]
                if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
                let title = m[3].isEmpty ? nil : String(m[3].dropFirst().dropLast())
                references[m[1].lowercased()] = (url, title)
                i += 1; continue
            }
            out.append(line); i += 1
        }
        return out
    }

    // MARK: - Blocks

    private func attr(_ line: Line, _ topLevel: Bool) -> String {
        topLevel && sourceLines ? " data-line=\"\(line.number)\"" : ""
    }

    mutating func blocks(_ lines: [Line], topLevel: Bool) -> String {
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.isBlank { i += 1; continue }
            let a = attr(line, topLevel)
            let text = line.text
            let trimmed = text.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if line.indent < 4, let fence = Rx.fence.firstMatch(text) {
                let marker = fence[1]
                let lang = fence[2].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].text.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(marker), t.allSatisfy({ $0 == marker.first }) { i += 1; break }
                    code.append(lines[i].dropping(line.indent).text)
                    i += 1
                }
                let open = lang.isEmpty ? "<pre\(a)><code>" : "<pre\(a)><code class=\"\(escapeAttr(lang))\">"
                out.append(open + escape(code.joined(separator: "\n")) + (code.isEmpty ? "" : "\n") + "</code></pre>")
                continue
            }

            // Display math block
            if line.indent < 4, trimmed.hasPrefix("$$") {
                var math = [String(trimmed.dropFirst(2))]
                var closed = trimmed.count > 2 && trimmed.hasSuffix("$$")
                if closed { math[0] = String(math[0].dropLast(2)) }
                i += 1
                while !closed, i < lines.count {
                    let t = lines[i].text
                    if let r = t.range(of: "$$") { math.append(String(t[..<r.lowerBound])); closed = true } else { math.append(t) }
                    i += 1
                }
                let body = math.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                out.append("<p\(a)><span class=\"math\">\\[\(escape(body))\\]</span></p>")
                continue
            }

            // ATX heading
            if line.indent < 4, let m = Rx.atx.firstMatch(text) {
                out.append(heading(level: m[1].count, raw: m[2], attr: a))
                i += 1; continue
            }

            // Horizontal rule
            if line.indent < 4, Rx.hr.matches(text) {
                out.append("<hr\(a) />")
                i += 1; continue
            }

            // TOC
            if Rx.toc.matches(trimmed) {
                out.append(Self.tocMarker)
                i += 1; continue
            }

            // Blockquote
            if line.indent < 4, trimmed.hasPrefix(">") {
                var inner: [Line] = []
                while i < lines.count {
                    let l = lines[i]
                    let t = l.text.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        inner.append(Line(text: String(rest), number: l.number)); i += 1
                    } else if !l.isBlank, !(inner.last?.isBlank ?? true), !startsBlock(l) {
                        inner.append(l); i += 1  // lazy continuation
                    } else if l.isBlank, i + 1 < lines.count, lines[i + 1].text.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                        inner.append(Line(text: "", number: l.number)); i += 1
                    } else { break }
                }
                out.append("<blockquote\(a)>\n" + blocks(inner, topLevel: false) + "\n</blockquote>")
                continue
            }

            // List
            if line.indent < 4, Rx.listItem.firstMatch(text) != nil {
                let (html, next) = list(lines, from: i, attr: a)
                out.append(html)
                i = next; continue
            }

            // Indented code
            if line.indent >= 4 {
                var code: [Line] = []
                while i < lines.count, lines[i].isBlank || lines[i].indent >= 4 {
                    code.append(lines[i].dropping(4)); i += 1
                }
                while code.last?.isBlank == true { code.removeLast() }
                out.append("<pre\(a)><code>" + escape(code.map(\.text).joined(separator: "\n")) + "\n</code></pre>")
                continue
            }

            // Table
            if text.contains("|"), i + 1 < lines.count, Rx.tableSeparator.matches(lines[i + 1].text) {
                let (html, next) = table(lines, from: i, attr: a)
                out.append(html)
                i = next; continue
            }

            // Content block (iA): a line that is only `/path` (plus optional "title").
            if line.indent < 4, trimmed.hasPrefix("/"), let html = contentBlock(trimmed, attr: a) {
                out.append(html)
                i += 1; continue
            }

            // HTML block
            if line.indent < 4, Rx.htmlBlock.matches(text) {
                var raw: [String] = []
                while i < lines.count, !lines[i].isBlank { raw.append(lines[i].text); i += 1 }
                out.append(raw.joined(separator: "\n"))
                continue
            }

            // Paragraph (or setext heading)
            var para: [String] = [text]
            i += 1
            var setext = 0
            while i < lines.count {
                let l = lines[i]
                if l.isBlank { break }
                if l.indent < 4, Rx.setext1.matches(l.text) { setext = 1; i += 1; break }
                if l.indent < 4, Rx.setext2.matches(l.text) { setext = 2; i += 1; break }
                if startsBlock(l) { break }
                para.append(l.text); i += 1
            }
            if setext > 0 {
                out.append(heading(level: setext, raw: para.joined(separator: "\n"), attr: a))
            } else {
                out.append(paragraph(para, attr: a))
            }
        }
        return out.joined(separator: "\n\n")
    }

    private func startsBlock(_ l: Line) -> Bool {
        guard l.indent < 4 else { return false }
        let t = l.text
        return Rx.atx.firstMatch(t) != nil || Rx.fence.firstMatch(t) != nil || Rx.hr.matches(t)
            || t.trimmingCharacters(in: .whitespaces).hasPrefix(">") || Rx.bulletItem.matches(t)
    }

    private mutating func paragraph(_ lines: [String], attr a: String) -> String {
        let joined = stripLeading(lines.joined(separator: "\n"))
        // An image alone in its paragraph becomes a figure, captioned by its alt text (MultiMarkdown 6).
        if let m = Rx.soloImage.firstMatch(joined) {
            return figure(src: m[2], alt: m[1], title: m[3].isEmpty ? nil : String(m[3].dropFirst().dropLast()), attr: a)
        }
        return "<p\(a)>" + inline(joined.trimmingCharacters(in: .whitespaces)) + "</p>"
    }

    private func stripLeading(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop(while: { $0 == " " || $0 == "\t" }) }
            .joined(separator: "\n")
    }

    private mutating func heading(level: Int, raw: String, attr a: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let r = text.range(of: #"[ \t]+#+[ \t]*$"#, options: .regularExpression) { text.removeSubrange(r) }
        else if text.allSatisfy({ $0 == "#" }) { text = "" }
        let html = inline(text)
        var id = Self.label(plain(html))
        if usedIDs.contains(id) {
            var n = 1
            while usedIDs.contains("\(id)-\(n)") { n += 1 }
            id = "\(id)-\(n)"
        }
        usedIDs.insert(id)
        headings.append(Heading(level: level, id: id, html: html))
        return "<h\(level) id=\"\(escapeAttr(id))\"\(a)>\(html)</h\(level)>"
    }

    // MultiMarkdown 6 label: drop whitespace and punctuation other than `-_:.`, lowercase.
    static func label(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "-_:.".unicodeScalars.contains($0)
        }.map(Character.init))
    }

    // MARK: Lists

    private mutating func list(_ lines: [Line], from start: Int, attr a: String) -> (String, Int) {
        let ordered = Rx.orderedItem.matches(lines[start].text)
        var items: [[Line]] = []
        var loose = false
        var i = start
        var sawBlank = false
        while i < lines.count {
            let l = lines[i]
            if l.isBlank {
                sawBlank = true
                if items.isEmpty { break }
                items[items.count - 1].append(l)
                i += 1; continue
            }
            if l.indent < 4, let m = Rx.listItem.firstMatch(l.text), !Rx.hr.matches(l.text) {
                if sawBlank, !items.isEmpty { loose = true }
                sawBlank = false
                // Content column: marker width, at most 4 (MultiMarkdown strips one tab stop).
                items.append([Line(text: String(l.text.dropFirst(m[0].count)), number: l.number)])
                i += 1; continue
            }
            if l.indent >= 4 {
                if sawBlank { loose = true }
                sawBlank = false
                items[items.count - 1].append(l.dropping(4))
                i += 1; continue
            }
            if sawBlank { break }       // unindented text after a blank line ends the list
            if startsBlock(l) { break }
            items[items.count - 1].append(l)  // lazy continuation
            i += 1
        }
        // Trailing blank lines belong after the list.
        for k in items.indices { while items[k].last?.isBlank == true { items[k].removeLast() } }
        if !loose { loose = items.contains { item in item.dropLast().contains(where: \.isBlank) && item.contains(where: { $0.indent == 0 && !$0.isBlank && $0.number != item[0].number }) } }

        var html = ordered ? "<ol\(a)>\n" : "<ul\(a)>\n"
        for var item in items {
            var checkbox: String?
            if let m = Rx.task.firstMatch(item[0].text) {
                checkbox = m[1] == " " ? "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled>"
                    : "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled checked>"
                item[0].text = m[2]
            }
            var body = blocks(item, topLevel: false)
            if !loose { body = unwrapParagraphs(body) }
            if let checkbox {
                html += "<li class=\"task-list-item\">" + checkbox + body + "</li>\n"
            } else {
                html += "<li>" + body + "</li>\n"
            }
        }
        html += ordered ? "</ol>" : "</ul>"
        return (html, i)
    }

    // Tight list items hold their text directly; nested blocks follow on the next line.
    private func unwrapParagraphs(_ body: String) -> String {
        var s = body
        if s.hasPrefix("<p>"), let end = s.range(of: "</p>") {
            s = String(s[s.index(s.startIndex, offsetBy: 3)..<end.lowerBound]) + String(s[end.upperBound...])
        }
        return s.replacingOccurrences(of: "\n\n<", with: "\n<")
    }

    // MARK: Tables

    private mutating func table(_ lines: [Line], from start: Int, attr a: String) -> (String, Int) {
        func cells(_ s: String) -> [String] {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
            var out: [String] = [], cur = "", code = false, prev: Character = " "
            for c in t {
                if c == "`" { code.toggle() }
                if c == "|", !code, prev != "\\" { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(c) }
                prev = c
            }
            out.append(cur.trimmingCharacters(in: .whitespaces))
            return out
        }
        let header = cells(lines[start].text)
        let aligns: [String?] = cells(lines[start + 1].text).map {
            let l = $0.hasPrefix(":"), r = $0.hasSuffix(":")
            return l && r ? "center" : r ? "right" : l ? "left" : nil
        }
        func style(_ k: Int) -> String {
            guard k < aligns.count, let al = aligns[k] else { return "" }
            return " style=\"text-align:\(al);\""
        }
        var i = start + 2
        var rows: [[String]] = []
        while i < lines.count, !lines[i].isBlank, lines[i].text.contains("|") {
            rows.append(cells(lines[i].text)); i += 1
        }
        var html = "<table\(a)>\n<colgroup>\n"
        for k in 0..<header.count { html += "<col\(style(k))/>\n" }
        html += "</colgroup>\n\n<thead>\n<tr>\n"
        for (k, c) in header.enumerated() { html += "\t<th\(style(k))>\(inline(c))</th>\n" }
        html += "</tr>\n</thead>\n\n<tbody>\n"
        for row in rows {
            html += "<tr>\n"
            for k in 0..<header.count { html += "\t<td\(style(k))>\(k < row.count ? inline(row[k]) : "")</td>\n" }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>"
        return (html, i)
    }

    // MARK: Content blocks

    private mutating func contentBlock(_ line: String, attr a: String) -> String? {
        guard let m = Rx.contentBlock.firstMatch(line) else { return nil }
        let path = m[1]
        let title = m[2].isEmpty ? nil : String(m[2].dropFirst().dropLast())
        let ext = (path as NSString).pathExtension.lowercased()
        let url = resolve(String(path.dropFirst()))
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if Self.imageExtensions.contains(ext) {
            return figure(src: String(path.dropFirst()), alt: title ?? "", title: title, attr: a)
        }
        guard exists, let url, depth < 3 else { return nil }
        switch ext {
        case "csv", "tsv":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return csvTable(text, separator: ext == "tsv" ? "\t" : ",", caption: title, attr: a)
        case "md", "markdown", "txt", "text", "mmd":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            var sub = State(baseURL: url.deletingLastPathComponent(), sourceLines: false)
            sub.depth = depth + 1
            sub.imageURL = imageURL
            sub.footnoteOrder = []
            return sub.document(text)
        default:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let code = "<pre><code class=\"\(escapeAttr(ext))\">" + escape(text) + "</code></pre>"
            return title.map { "<figure\(a)>\n\(code)\n<figcaption>\(inline($0))</figcaption>\n</figure>" } ?? code
        }
    }

    private mutating func csvTable(_ text: String, separator: Character, caption: String?, attr a: String) -> String {
        let rows = text.split(whereSeparator: \.isNewline).map { $0.split(separator: separator, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } }
        guard let header = rows.first else { return "" }
        var html = "<table\(a)>\n"
        if let caption { html += "<caption>\(inline(caption))</caption>\n" }
        html += "<thead>\n<tr>\n" + header.map { "\t<th>\(escape($0))</th>\n" }.joined() + "</tr>\n</thead>\n\n<tbody>\n"
        for row in rows.dropFirst() { html += "<tr>\n" + row.map { "\t<td>\(escape($0))</td>\n" }.joined() + "</tr>\n" }
        return html + "</tbody>\n</table>"
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp", "svg", "bmp", "pdf"]

    private func resolve(_ path: String) -> URL? {
        let decoded = path.removingPercentEncoding ?? path
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        return baseURL?.appendingPathComponent(decoded)
    }

    private mutating func figure(src: String, alt: String, title: String?, attr a: String) -> String {
        var img = "<img src=\"\(escapeAttr(imageURL?(src, baseURL) ?? src))\" alt=\"\(escapeAttr(plain(inline(alt))))\""
        if let title { img += " title=\"\(escapeAttr(title))\"" }
        img += " />"
        let caption = alt.isEmpty ? "" : "\n<figcaption>\(inline(alt))</figcaption>"
        return "<figure\(a)>\n\(img)\(caption)\n</figure>"
    }

    // MARK: TOC and footnotes

    static let tocMarker = "\u{1}TOC\u{1}"

    private func toc() -> String {
        guard !headings.isEmpty else { return "<div class=\"TOC\">\n</div>" }
        var html = "<div class=\"TOC\">\n\n<ul>\n"
        var stack = [headings[0].level]
        for (k, h) in headings.enumerated() {
            if k > 0 {
                if h.level > stack.last! { html += "\n<ul>\n"; stack.append(h.level) }
                else {
                    html += "</li>\n"
                    while stack.count > 1, h.level < stack.last! { stack.removeLast(); html += "</ul>\n</li>\n" }
                }
            }
            html += "<li><a href=\"#\(escapeAttr(h.id))\">\(h.html)</a>"
        }
        html += "</li>\n"
        while stack.count > 1 { stack.removeLast(); html += "</ul>\n</li>\n" }
        return html + "</ul>\n</div>"
    }

    private mutating func footnotes() -> String {
        guard !footnoteOrder.isEmpty else { return "" }
        var html = "\n\n<div class=\"footnotes\">\n<hr />\n<ol>\n\n"
        var k = 0
        while k < footnoteOrder.count {  // footnotes may reference further footnotes
            let id = footnoteOrder[k]
            let n = k + 1
            var body: String
            if let inlineHTML = inlineFootnotes[id] {
                body = "<p>" + inlineHTML + "</p>"
            } else {
                body = blocks(footnoteText[id] ?? [], topLevel: false)
            }
            let back = " <a href=\"#fnr\(n)\" title=\"return to article\" class=\"reversefootnote\">&#8617;&#xFE0E;</a>"
            if body.hasSuffix("</p>") { body = String(body.dropLast(4)) + back + "</p>" } else { body += "\n<p>" + back + "</p>" }
            html += "<li id=\"fn\(n)\">\n\(body)\n</li>\n\n"
            k += 1
        }
        return html + "</ol>\n</div>"
    }

    // MARK: - Inline

    mutating func inline(_ s: String) -> String {
        var p = InlineParser(chars: Array(s), state: self)
        let out = p.run()
        self = p.state
        return out
    }

    fileprivate mutating func footnoteNumber(_ id: String) -> Int? {
        let key = id.lowercased()
        guard footnoteText[key] != nil || inlineFootnotes[key] != nil else { return nil }
        if let k = footnoteOrder.firstIndex(of: key) { return k + 1 }
        footnoteOrder.append(key)
        return footnoteOrder.count
    }

    fileprivate mutating func inlineFootnote(_ html: String) -> Int {
        let key = "\u{1}inline\(inlineFootnotes.count)"
        inlineFootnotes[key] = html
        footnoteOrder.append(key)
        return footnoteOrder.count
    }
}

// MARK: - Inline parser

private struct InlineParser {
    let chars: [Character]
    var state: State
    var i = 0

    enum Token { case html(String), delim(Character, Int, open: Bool, close: Bool) }
    var tokens: [Token] = []
    var text = ""

    init(chars: [Character], state: State) {
        self.chars = chars
        self.state = state
    }

    mutating func flush() {
        if !text.isEmpty { tokens.append(.html(text)); text = "" }
    }

    func at(_ k: Int) -> Character? { k >= 0 && k < chars.count ? chars[k] : nil }

    func starts(_ s: String, _ k: Int) -> Bool {
        var j = k
        for c in s { guard at(j) == c else { return false }; j += 1 }
        return true
    }

    func find(_ s: String, from k: Int) -> Int? {
        var j = k
        while j < chars.count { if starts(s, j) { return j }; j += 1 }
        return nil
    }

    func string(_ a: Int, _ b: Int) -> String { a < b ? String(chars[a..<b]) : "" }

    // Index after the bracket that closes the one at `k`, honouring nesting and code spans.
    func closingBracket(_ k: Int) -> Int? {
        var depth = 0, j = k
        while j < chars.count {
            let c = chars[j]
            if c == "\\" { j += 2; continue }
            if c == "`" {
                var n = 0; while at(j + n) == "`" { n += 1 }
                if let e = find(String(repeating: "`", count: n), from: j + n) { j = e + n; continue }
            }
            if c == "[" { depth += 1 }
            if c == "]" { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }

    // `(url "title")` starting at `k` (the opening paren); returns url, title and the index after `)`.
    func destination(_ k: Int) -> (String, String?, Int)? {
        guard at(k) == "(" else { return nil }
        var j = k + 1
        while at(j) == " " { j += 1 }
        var url = ""
        if at(j) == "<" {
            guard let e = find(">", from: j) else { return nil }
            url = string(j + 1, e); j = e + 1
        } else {
            var depth = 0
            while let c = at(j), c != " " || depth > 0 {
                if c == "(" { depth += 1 }
                if c == ")" { if depth == 0 { break }; depth -= 1 }
                if c == "\\", let n = at(j + 1) { url.append(n); j += 2; continue }
                url.append(c); j += 1
            }
        }
        while at(j) == " " { j += 1 }
        var title: String?
        if let q = at(j), q == "\"" || q == "'" {
            guard let e = find(String(q), from: j + 1) else { return nil }
            title = string(j + 1, e); j = e + 1
            while at(j) == " " { j += 1 }
        }
        guard at(j) == ")" else { return nil }
        return (url, title, j + 1)
    }

    static let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
    func isSpace(_ c: Character?) -> Bool { c.map { $0.isWhitespace } ?? true }
    func isPunct(_ c: Character?) -> Bool { c.map { $0.unicodeScalars.allSatisfy { Self.punctuation.contains($0) } } ?? false }

    mutating func run() -> String {
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if let n = at(i + 1), "\\`*_{}[]()#+-.!~=|<>$^\"'".contains(n) { text += escape(String(n)); i += 2 }
                else if at(i + 1) == "\n" { text += "<br />\n"; i += 2 }
                else if starts("\\(", i), let e = find("\\)", from: i + 2) { math(i, e + 2) }
                else if starts("\\[", i), let e = find("\\]", from: i + 2) { math(i, e + 2) }
                else { text += "\\"; i += 1 }
            case "`":
                var n = 0; while at(i + n) == "`" { n += 1 }
                if let e = find(String(repeating: "`", count: n), from: i + n), at(e + n) != "`" {
                    var code = string(i + n, e).replacingOccurrences(of: "\n", with: " ")
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 1 { code = String(code.dropFirst().dropLast()) }
                    text += "<code>" + escape(code) + "</code>"
                    i = e + n
                } else { text += String(repeating: "`", count: n); i += n }
            case "$":
                // $math$: no space just inside the dollars, no digit right after the closing one.
                if at(i + 1) == "$", let e = find("$$", from: i + 2) { math(i, e + 2) }
                else if let n = at(i + 1), !n.isWhitespace, n != "$", let e = closingDollar(i + 1) { math(i, e + 1) }
                else { text += "$"; i += 1 }
            case "<":
                if let e = find(">", from: i + 1) {
                    let inner = string(i + 1, e)
                    if inner.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:[^\s<>]*$"#, options: .regularExpression) != nil {
                        text += "<a href=\"\(escapeAttr(inner))\">\(escape(inner))</a>"; i = e + 1; continue
                    }
                    if inner.range(of: #"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$"#, options: .regularExpression) != nil {
                        text += "<a href=\"mailto:\(escapeAttr(inner))\">\(escape(inner))</a>"; i = e + 1; continue
                    }
                    if inner.range(of: #"^(/?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?|!--.*--)$"#, options: .regularExpression) != nil {
                        text += "<" + inner + ">"; i = e + 1; continue
                    }
                }
                text += "&lt;"; i += 1
            case "!":
                if at(i + 1) == "[", let close = closingBracket(i + 1) {
                    let alt = string(i + 2, close)
                    if let (url, title, end) = destination(close + 1) {
                        image(url, alt: alt, title: title); i = end; continue
                    }
                    if let (ref, end) = reference(close + 1, fallback: alt), let def = state.references[ref] {
                        image(def.url, alt: alt, title: def.title); i = end; continue
                    }
                }
                text += "!"; i += 1
            case "[":
                if link() { continue }
                text += "["; i += 1
            case "^":
                if at(i + 1) == "[", let close = closingBracket(i + 1) {
                    var sub = state
                    let html = sub.inline(string(i + 2, close))
                    state = sub
                    let n = state.inlineFootnote(html)
                    text += footnoteRef(n); i = close + 1; continue
                }
                text += "^"; i += 1
            case "*", "_", "~", "=":
                var n = 0; while at(i + n) == c { n += 1 }
                if (c == "~" || c == "=") && n < 2 { text.append(c); i += n; continue }
                let before = at(i - 1), after = at(i + n)
                let leftFlank = !isSpace(after) && (!isPunct(after) || isSpace(before) || isPunct(before))
                let rightFlank = !isSpace(before) && (!isPunct(before) || isSpace(after) || isPunct(after))
                var open = leftFlank, close = rightFlank
                if c == "_" {
                    open = leftFlank && (!rightFlank || isPunct(before))
                    close = rightFlank && (!leftFlank || isPunct(after))
                }
                flush()
                tokens.append(.delim(c, n, open: open, close: close))
                i += n
            case "&":
                if let e = find(";", from: i + 1), e - i < 10, string(i + 1, e).range(of: #"^#?[A-Za-z0-9]+$"#, options: .regularExpression) != nil {
                    text += string(i, e + 1); i = e + 1
                } else { text += "&amp;"; i += 1 }
            case ">": text += "&gt;"; i += 1
            case "\"": text += "&quot;"; i += 1
            case "\n":
                if text.hasSuffix("  ") {
                    while text.hasSuffix(" ") { text.removeLast() }
                    text += "<br />\n"
                } else {
                    while text.hasSuffix(" ") { text.removeLast() }
                    text += "\n"
                }
                i += 1
            case "h", "w":
                if let (url, end) = bareURL() {
                    let href = url.hasPrefix("www.") ? "http://" + url : url
                    text += "<a class=\"autolink\" href=\"\(escapeAttr(href))\">\(escape(url))</a>"; i = end; continue
                }
                text.append(c); i += 1
            default:
                text.append(c); i += 1
            }
        }
        flush()
        return emphasis()
    }

    func closingDollar(_ k: Int) -> Int? {
        var j = k
        while j < chars.count {
            if chars[j] == "\n", at(j + 1) == "\n" { return nil }
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "$", !chars[j - 1].isWhitespace, !(at(j + 1)?.isNumber ?? false) { return j }
            j += 1
        }
        return nil
    }

    mutating func math(_ a: Int, _ b: Int) {
        var body = string(a, b)
        if body.hasPrefix("$$") { body = "\\[" + body.dropFirst(2).dropLast(2) + "\\]" }
        else if body.hasPrefix("$") { body = "\\(" + body.dropFirst().dropLast() + "\\)" }
        text += "<span class=\"math\">" + escape(body) + "</span>"
        i = b
    }

    func bareURL() -> (String, Int)? {
        let prev = at(i - 1)
        if let prev, prev.isLetter || prev.isNumber || prev == "/" || prev == "\"" || prev == "=" { return nil }
        guard starts("http://", i) || starts("https://", i) || starts("www.", i) else { return nil }
        var j = i
        while let c = at(j), !c.isWhitespace, c != "<", c != ">", c != "\"" { j += 1 }
        while let c = at(j - 1), ".,:;!?)]'".contains(c) {
            if c == ")" { let s = string(i, j); if s.filter({ $0 == "(" }).count >= s.filter({ $0 == ")" }).count { break } }
            j -= 1
        }
        guard j - i > 8 else { return nil }
        return (string(i, j), j)
    }

    func reference(_ k: Int, fallback: String) -> (String, Int)? {
        if at(k) == "[", let e = find("]", from: k + 1) {
            let id = string(k + 1, e)
            return ((id.isEmpty ? fallback : id).lowercased(), e + 1)
        }
        return (fallback.lowercased(), k)
    }

    func footnoteRef(_ n: Int) -> String {
        "<sup><a href=\"#fn\(n)\" id=\"fnr\(n)\" title=\"see footnote\" class=\"footnote\">\(n)</a></sup>"
    }

    mutating func image(_ url: String, alt: String, title: String?) {
        var sub = state
        let altText = plain(sub.inline(alt))
        state = sub
        text += "<img src=\"\(escapeAttr(state.imageURL?(url, state.baseURL) ?? url))\" alt=\"\(escapeAttr(altText))\""
        if let title { text += " title=\"\(escapeAttr(title))\"" }
        text += " />"
    }

    mutating func link() -> Bool {
        // [[wikilink]] / [[target|label]]
        if at(i + 1) == "[", let e = find("]]", from: i + 2) {
            let inner = string(i + 2, e)
            if !inner.isEmpty, !inner.contains("\n"), !inner.contains("[") {
                let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
                let target = parts[0], label = parts.count > 1 ? parts[1] : parts[0]
                text += "<a class=\"wikilink\" title=\"\(escapeAttr(target))\" href=\"\(escapeAttr(target))\">\(escape(label))</a>"
                i = e + 2
                return true
            }
        }
        guard let close = closingBracket(i) else { return false }
        let label = string(i + 1, close)
        // [^footnote]
        if label.hasPrefix("^") {
            if let n = state.footnoteNumber(String(label.dropFirst())) {
                text += footnoteRef(n); i = close + 1; return true
            }
            return false
        }
        var href: String?, title: String?, end = close + 1
        if let (u, t, e) = destination(close + 1) { href = u; title = t; end = e }
        else if let (ref, e) = reference(close + 1, fallback: label), let def = state.references[ref] { href = def.url; title = def.title; end = e }
        guard let href else { return false }
        var sub = state
        let inner = sub.inline(label)
        state = sub
        text += "<a href=\"\(escapeAttr(href))\"" + (title.map { " title=\"\(escapeAttr($0))\"" } ?? "") + ">\(inner)</a>"
        i = end
        return true
    }

    // CommonMark's delimiter pass, reduced: `*`/`_` make em/strong, `~~` del, `==` mark.
    mutating func emphasis() -> String {
        struct D { var c: Character; var n: Int; var open: Bool; var close: Bool; var idx: Int }
        var out: [String] = []
        var left: [Int: String] = [:]   // tags opened right after token index
        var right: [Int: String] = [:]  // tags closed right before token index (prepended)
        var stack: [D] = []
        var counts: [Int: Int] = [:]
        for (k, t) in tokens.enumerated() {
            switch t {
            case .html(let s): out.append(s)
            case .delim(let c, let n, let open, let close):
                out.append("")
                counts[k] = n
                var remaining = n
                if close {
                    var j = stack.count - 1
                    while j >= 0, remaining > 0 {
                        if stack[j].c == c, stack[j].open, counts[stack[j].idx]! > 0 {
                            let avail = counts[stack[j].idx]!
                            let use: Int
                            if c == "~" || c == "=" {
                                guard avail >= 2, remaining >= 2 else { j -= 1; continue }
                                use = 2
                            } else { use = (avail >= 2 && remaining >= 2) ? 2 : 1 }
                            let tag = c == "~" ? "del" : c == "=" ? "mark" : use == 2 ? "strong" : "em"
                            left[stack[j].idx, default: ""] = "<\(tag)>" + left[stack[j].idx, default: ""]
                            right[k, default: ""] += "</\(tag)>"
                            counts[stack[j].idx]! -= use
                            remaining -= use
                            stack.removeSubrange((j + 1)...)
                            if counts[stack[j].idx]! == 0 { stack.remove(at: j) }
                            j = stack.count - 1
                        } else { j -= 1 }
                    }
                }
                counts[k] = remaining
                if remaining > 0, open { stack.append(D(c: c, n: remaining, open: true, close: close, idx: k)) }
            }
        }
        // Rebuild: leftover delimiter characters stay as text, on the outside of the tags they produced.
        var result = ""
        for (k, t) in tokens.enumerated() {
            if case .delim(let c, _, _, _) = t {
                let rest = String(repeating: c, count: counts[k] ?? 0)
                result += (right[k] ?? "") + rest + (left[k] ?? "")
            } else { result += out[k] }
        }
        return result
    }
}

// MARK: - Helpers

fileprivate func escape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for c in s {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        default: out.append(c)
        }
    }
    return out
}

fileprivate func escapeAttr(_ s: String) -> String { escape(s).replacingOccurrences(of: "\"", with: "&quot;") }

/// Text content of an HTML fragment (tags removed, the four basic entities decoded).
fileprivate func plain(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
}

private enum Rx {
    struct R {
        let re: NSRegularExpression
        init(_ p: String) { re = try! NSRegularExpression(pattern: p) }
        func matches(_ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        func firstMatch(_ s: String) -> [String]? {
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (0..<m.numberOfRanges).map { k in Range(m.range(at: k), in: s).map { String(s[$0]) } ?? "" }
        }
    }
    static let atx = R(#"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$"#)
    static let hr = R(#"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    static let fence = R(#"^ {0,3}(`{3,}|~{3,})(.*)$"#)
    static let setext1 = R(#"^ {0,3}=+[ \t]*$"#)
    static let setext2 = R(#"^ {0,3}-+[ \t]*$"#)
    static let listItem = R(#"^ {0,3}([*+-]|\d+[.)])(?:[ \t]+|$)"#)
    static let bulletItem = R(#"^ {0,3}[*+-][ \t]+\S"#)
    static let orderedItem = R(#"^ {0,3}\d+[.)]"#)
    static let task = R(#"^\[([ xX])\][ \t]+(.*)$"#)
    static let toc = R(#"^\{\{TOC(?::\d+(?:-\d+)?)?\}\}$"#)
    static let tableSeparator = R(#"^ {0,3}\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    static let htmlBlock = R(#"^ {0,3}<(?:/?(?:div|table|pre|p|ul|ol|dl|blockquote|h[1-6]|figure|section|article|aside|header|footer|nav|details|summary|iframe|video|audio|canvas|form|hr|style|script)\b|!--)"#)
    static let footnoteDef = R(#"^ {0,3}\[\^([^\]]+)\]:[ \t]*(.*)$"#)
    static let linkDef = R(#"^ {0,3}\[([^\]^][^\]]*)\]:[ \t]*(<[^>]*>|\S+)(?:[ \t]+("[^"]*"|'[^']*'|\([^)]*\)))?[ \t]*$"#)
    static let soloImage = R(#"^!\[([^\]]+)\]\(([^)\s]+)(?:[ \t]+("[^"]*"))?\)$"#)
    static let contentBlock = R(#"^(/\S+)(?:[ \t]+("[^"]*"|\([^)]*\)))?$"#)
}
