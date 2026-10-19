import AppKit

// Format bar actions: insert the Markdown through the text view so they undo and restyle like typing.
extension LibraryWindowController {
    private static let blockPrefix = try! NSRegularExpression(pattern: #"^(#{1,6} |[ \t]*(?:[-*+] \[[ xX]\] |[-*+] |\d+\. )|> )"#)
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6}) "#)
    private static let listMarker = try! NSRegularExpression(pattern: #"^[ \t]*([-*+]|\d+\.) "#)

    private var lineRange: NSRange {
        (textView.string as NSString).lineRange(for: textView.selectedRange())
    }

    // Block style of the caret's line.
    func block() -> (FormatBar.Action, Int) {
        let ns = textView.string as NSString
        let line = ns.lineRange(for: NSRange(location: min(textView.selectedRange().location, ns.length), length: 0))
        let text = ns.substring(with: line)
        let range = NSRange(location: 0, length: (text as NSString).length)
        if let m = Self.heading.firstMatch(in: text, range: range) { return (.heading, m.range(at: 1).length) }
        if Self.listMarker.firstMatch(in: text, range: range) != nil { return (.list, 0) }
        if text.hasPrefix(">") { return (.blockquote, 0) }
        return (.body, 0)
    }

    private func replace(_ range: NSRange, with string: String, select: NSRange? = nil) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        textView.setSelectedRange(select ?? NSRange(location: range.location + (string as NSString).length, length: 0))
    }

    // Replace the block marker of every selected line with `prefix` (empty = Body).
    private func setPrefix(_ prefix: @escaping (Int) -> String) {
        let ns = textView.string as NSString
        let lines = lineRange
        var out = ""
        var index = 0
        ns.enumerateSubstrings(in: lines, options: [.byLines]) { line, _, enclosing, _ in
            guard let line else { return }
            let terminator = ns.substring(with: NSRange(location: enclosing.location + (line as NSString).length,
                                                       length: enclosing.length - (line as NSString).length))
            let stripped = Self.blockPrefix.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            out += prefix(index) + stripped + terminator
            index += 1
        }
        if lines.length == 0 { out = prefix(0) }
        let caretAtEnd = (out as NSString).length - (out.hasSuffix("\n") ? 1 : 0)
        replace(lines, with: out, select: NSRange(location: lines.location + caretAtEnd, length: 0))
    }

    // Wrap the selection (or insert an empty pair with the caret inside). Pressing again unwraps:
    // markers right around the selection, or inside it at both ends, are removed.
    private func wrap(_ left: String, _ right: String) {
        let ns = textView.string as NSString
        let range = textView.selectedRange()
        let selected = ns.substring(with: range)
        let l = (left as NSString).length, r = (right as NSString).length
        if range.length == 0 {
            // Caret inside the same formatting: take it off, the caret stays on its character.
            let line = ns.paragraphRange(for: range)
            let text = ns.substring(with: line) as NSString
            for (span, kind) in Markdown.spans(in: text as String, range: NSRange(location: 0, length: text.length))
                where Markdown.markerLength(of: kind, span: span, in: text) == l
                    && text.substring(with: span).hasPrefix(left) && text.substring(with: span).hasSuffix(right) {
                let whole = NSRange(location: line.location + span.location, length: span.length)
                guard range.location >= whole.location + l, range.location <= NSMaxRange(whole) - r else { continue }
                let inner = ns.substring(with: NSRange(location: whole.location + l, length: whole.length - l - r))
                return replace(whole, with: inner, select: NSRange(location: range.location - l, length: 0))
            }
            // Caret in or right after a word: format the word, the caret stays where it was in it.
            let isWord = { (r: NSRange) in r.length > 0 && ns.substring(with: r).unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
            var word = textView.selectionRange(forProposedRange: range, granularity: .selectByWord)
            if !isWord(word), range.location > 0 {
                word = textView.selectionRange(forProposedRange: NSRange(location: range.location - 1, length: 0), granularity: .selectByWord)
            }
            if isWord(word), NSLocationInRange(range.location, word) || range.location == NSMaxRange(word) {
                return replace(word, with: left + ns.substring(with: word) + right, select: NSRange(location: range.location + l, length: 0))
            }
        }
        if range.location >= l, NSMaxRange(range) + r <= ns.length,
           ns.substring(with: NSRange(location: range.location - l, length: l)) == left,
           ns.substring(with: NSRange(location: NSMaxRange(range), length: r)) == right {
            return replace(NSRange(location: range.location - l, length: range.length + l + r), with: selected,
                           select: NSRange(location: range.location - l, length: range.length))
        }
        if range.length >= l + r, selected.hasPrefix(left), selected.hasSuffix(right) {
            let inner = (selected as NSString).substring(with: NSRange(location: l, length: range.length - l - r))
            return replace(range, with: inner, select: NSRange(location: range.location, length: (inner as NSString).length))
        }
        replace(range, with: left + selected + right,
                select: NSRange(location: range.location + l, length: (selected as NSString).length))
    }

    // MARK: - Keyboard shortcuts (Notion's, mapped to Markdown)

    @objc func formatBold(_ sender: Any?) { wrap("**", "**") }
    @objc func formatItalic(_ sender: Any?) { wrap("*", "*") }
    @objc func formatStrikethrough(_ sender: Any?) { wrap("~~", "~~") }
    @objc func formatInlineCode(_ sender: Any?) { wrap("`", "`") }
    @objc func formatHighlight(_ sender: Any?) { wrap("==", "==") }
    @objc func formatLink(_ sender: Any?) { format(.link, 0) }

    // ⌘⌥0–6: the same key on a line that already has that style turns it back into body text.
    @objc func formatBlock(_ sender: NSMenuItem) {
        let (current, level) = block()
        let text = (textView.string as NSString).substring(with: lineRange)
        switch sender.tag {
        case 1, 2, 3:
            format(current == .heading && level == sender.tag ? .body : .heading, sender.tag)
        case 4:   // to-do
            format(text.range(of: #"^[ \t]*[-*+] \[[ xX]\] "#, options: .regularExpression) != nil ? .body : .list, 2)
        case 5:   // bulleted
            let bulleted = text.range(of: #"^[ \t]*[-*+] (?!\[[ xX]\] )"#, options: .regularExpression) != nil
            format(bulleted ? .body : .list, 0)
        case 6:   // numbered
            format(text.range(of: #"^[ \t]*\d+\. "#, options: .regularExpression) != nil ? .body : .list, 1)
        default:
            format(.body, 0)
        }
    }

    // ⌘⌥8: fence the selected lines (or open an empty block with the caret inside).
    @objc func formatCodeBlock(_ sender: Any?) {
        window?.makeFirstResponder(textView)
        let ns = textView.string as NSString
        let range = textView.selectedRange()
        if range.length == 0 {
            let lead = range.location > 0 && ns.character(at: range.location - 1) != 10 ? "\n" : ""
            return replace(range, with: lead + "```\n\n```", select: NSRange(location: range.location + (lead as NSString).length + 4, length: 0))
        }
        let lines = lineRange
        var body = ns.substring(with: lines)
        if !body.hasSuffix("\n") { body += "\n" }
        replace(lines, with: "```\n" + body + "```\n")
    }

    func format(_ action: FormatBar.Action, _ option: Int) {
        window?.makeFirstResponder(textView)
        switch action {
        case .body: setPrefix { _ in "" }
        case .heading: setPrefix { _ in String(repeating: "#", count: max(option, 1)) + " " }
        case .list: setPrefix { option == 1 ? "\($0 + 1). " : option == 2 ? "- [ ] " : "- " }
        case .blockquote: setPrefix { _ in "> " }
        case .bold: wrap("**", "**")
        case .italic: wrap("*", "*")   // `*` works inside CJK text; `_` doesn't (CommonMark)
        case .strikethrough: wrap("~~", "~~")
        case .wikilink: wrap("[[", "]]")
        case .link:
            let range = textView.selectedRange()
            let selected = (textView.string as NSString).substring(with: range)
            let text = "[\(selected)]()"
            // Caret goes into the URL when there is link text, else into the text.
            let caret = selected.isEmpty ? range.location + 1 : range.location + (text as NSString).length - 1
            replace(range, with: text, select: NSRange(location: caret, length: 0))
        case .footnote:
            let ns = textView.string as NSString
            var n = 1
            while ns.range(of: "[^\(n)]").location != NSNotFound { n += 1 }
            let marker = "[^\(n)]"
            let range = textView.selectedRange()
            replace(NSRange(location: NSMaxRange(range), length: 0), with: marker)
            let end = (textView.string as NSString).length
            let note = (textView.string.hasSuffix("\n") ? "\n" : "\n\n") + marker + ": "
            replace(NSRange(location: end, length: 0), with: note)
        case .table:
            let template = "| Column | Column |\n| ------ | ------ |\n| Cell   | Cell   |\n"
            let range = textView.selectedRange()
            let ns = textView.string as NSString
            let lead = range.location > 0 && ns.character(at: range.location - 1) != 10 ? "\n\n" : ""
            replace(range, with: lead + template)
        case .toc:
            let range = textView.selectedRange()
            replace(range, with: "{{TOC}}\n")
        }
        formatBar.update(block: block(), text: textView.string)
    }
}
