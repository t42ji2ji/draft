import AppKit

final class EditorTextView: NSTextView {
    // iA's focus scopes; `typewriter` only scrolls, it doesn't dim.
    enum FocusScope: Int { case typewriter, paragraph, sentence }

    // Where focus mode keeps the caret line: iA centres it; upper third and free scrolling are Draft options.
    enum TypewriterPosition: Int {
        case center, upper, off
        var fraction: CGFloat? { [CGFloat(0.5), 1.0 / 3, nil][rawValue] }
    }
    var typewriterPosition = TypewriterPosition(rawValue: UserDefaults.standard.integer(forKey: "TypewriterPosition")) ?? .center
    private var typewriter: CGFloat? { focusMode ? typewriterPosition.fraction : nil }

    var focusMode = UserDefaults.standard.object(forKey: "FocusMode") as? Bool ?? true
    static let focusModeDidChange = Notification.Name("DraftFocusModeDidChange")
    var focusScope = FocusScope(rawValue: UserDefaults.standard.object(forKey: "FocusScope") as? Int ?? 2) ?? .sentence
    var syntaxMask = PartOfSpeech(rawValue: UserDefaults.standard.integer(forKey: "SyntaxControl"))
    var styleMask = StyleCategory(rawValue: UserDefaults.standard.integer(forKey: "StyleCheck"))
    private var paragraphCache: [String: ParagraphMarks] = [:]
    private(set) var typography = Typography(viewportWidth: 720, dark: false, retina: true)
    private var pendingEdit: NSRange?
    private var restyled = false
    private var codeBlocks: [NSRange] = []
    private var editorLayoutManager: EditorLayoutManager? { layoutManager as? EditorLayoutManager }
    static let tabWidth = 2      // iA defaults: tab width 2, indent width 4, indent with tabs

    func configure() {
        textContainer?.replaceLayoutManager(EditorLayoutManager())
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
        applyCaretColor()
        layoutManager?.usesFontLeading = false
        layoutManager?.allowsNonContiguousLayout = true  // long documents: don't relayout everything after an edit
        textContainer?.widthTracksTextView = false
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        relayout()
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.restyled = false   // new type: reapply attributes to the whole document
            self.relayout()
            self.applyCaretColor()  // the palette may have changed
        }
        NotificationCenter.default.addObserver(forName: Settings.caretColorDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyCaretColor()
        }
        NotificationCenter.default.addObserver(forName: Settings.paperOpacityDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
        // ⌘D in the Settings window's sample editor also switches the library editor, and the other way round.
        NotificationCenter.default.addObserver(forName: Self.focusModeDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.focusMode = UserDefaults.standard.bool(forKey: "FocusMode")
            self.relayout()
            self.recolor()
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportScrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    // Coalesced: during the typewriter scroll animation this runs every frame, and colouring inline held the animation up.
    @objc private func viewportScrolled() { setNeedsRecolor() }

    private func applyCaretColor() {
        insertionPointColor = Theme.caret
        selectedTextAttributes = [.backgroundColor: Theme.selection]
        // 注音 composition underline, blue by default.
        markedTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: Theme.markedUnderline]
        needsDisplay = true
        updateInsertionPointStateAndRestartTimer(true)
    }

    // Recompute typography for the current viewport and reapply it to the whole document.
    func relayout() {
        guard let scrollView = enclosingScrollView, let textContainer else { return }
        let viewport = scrollView.contentSize
        let old = typography
        typography = Typography(viewportWidth: viewport.width,
                                dark: effectiveAppearance.isDark,
                                retina: (window?.backingScaleFactor ?? 2) > 1)
        textContainer.size = NSSize(width: typography.containerWidth, height: .greatestFiniteMagnitude)
        textContainerInset = NSSize(width: typography.insetWidth, height: insetHeight)
        minSize.height = viewport.height   // short documents still fill the page, so the paper lines do too
        editorLayoutManager?.columnInset = typography.en * typography.marginChars
        // Reapplying attributes relayouts the whole document; skip it during live resize unless the type changed.
        if !restyled || typography.font != old.font || typography.marginChars != old.marginChars {
            restyled = true
            codeBlocks = Markdown.codeBlocks(in: string)
            typingAttributes = attributes(hanging: 0)
            // An empty document has no paragraph to carry the style; the caret falls back to this.
            defaultParagraphStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle
            applyStyles(in: NSRange(location: 0, length: (string as NSString).length))
        }
        if typewriter != nil { centerCaret(animated: false) }
    }

    private var insetHeight: CGFloat {
        guard let scrollView = enclosingScrollView, let window else { return 30 }
        if let f = typewriter {
            // Symmetric inset sized for the space below the caret line; the top is set by textContainerOrigin.
            return ceil(scrollView.contentSize.height * (1 - f) - typography.lineHeight / 2) - 3
        }
        let titlebar = window.frame.height - window.contentLayoutRect.height
        return ceil(titlebar + 4 + min(typography.en * typography.marginChars, 20))
    }

    private func attributes(hanging: Int, indent: Int = 0) -> [NSAttributedString.Key: Any] {
        let margin = typography.en * typography.marginChars
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = typography.lineHeight
        paragraph.maximumLineHeight = typography.lineHeight
        paragraph.headIndent = margin + typography.en * CGFloat(indent)
        paragraph.firstLineHeadIndent = hanging > 0 && CGFloat(hanging) <= typography.marginChars
            ? margin - typography.en * CGFloat(hanging) : margin
        paragraph.tailIndent = -margin
        paragraph.defaultTabInterval = typography.en * CGFloat(Self.tabWidth)
        paragraph.tabStops = []
        return [.font: typography.font, .foregroundColor: Theme.text,
                .paragraphStyle: paragraph, .baselineOffset: typography.baselineOffset]
    }

    // MARK: - Styling

    // Real attributes (font, paragraph) for the paragraphs touching `range`.
    private func applyStyles(in range: NSRange) {
        guard let textStorage else { return }
        let ns = string as NSString
        // One character past the edit: after Return at the end of "### Title", the old line break becomes an empty
        // paragraph that still has the heading's hanging indent, which would put the caret in the margin.
        let paragraphs = ns.paragraphRange(for: NSRange(location: range.location, length: min(range.length + 1, ns.length - range.location)))
        let inCode = { (r: NSRange) in self.codeBlocks.contains { NSIntersectionRange($0, r).length == r.length && r.length > 0 } }
        textStorage.beginEditing()
        ns.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            if inCode(enclosing) {
                textStorage.setAttributes(self.attributes(hanging: 0), range: enclosing)
                return
            }
            let hang = Markdown.hangingMarkerLength(in: self.string, paragraph: enclosing)
            let indent = Markdown.blockMarkerColumns(in: self.string, paragraph: enclosing, tabWidth: Self.tabWidth)
            textStorage.setAttributes(self.attributes(hanging: hang, indent: indent), range: enclosing)
        }
        if paragraphs.length == 0 { textStorage.setAttributes(typingAttributes, range: paragraphs) }
        for (span, kind) in Markdown.spans(in: string, range: paragraphs) where !inCode(span) {
            if kind == .strong || kind == .heading { textStorage.addAttribute(.font, value: typography.boldFont, range: span) }
            if kind == .emphasis {
                textStorage.addAttribute(.font, value: typography.italicFont, range: span)
                if Settings.cjkEmphasis == .italic, let cjkItalic = typography.cjkItalicFont {
                    Markdown.cjk.enumerateMatches(in: string, range: span) { match, _, _ in
                        if let match { textStorage.addAttribute(.font, value: cjkItalic, range: match.range) }
                    }
                }
            }
        }
        if let fullSpace = typography.fullSpaceFont {
            Markdown.fullWidthPunctuation.enumerateMatches(in: string, range: paragraphs) { match, _, _ in
                if let match { textStorage.addAttribute(.font, value: fullSpace, range: match.range) }
            }
        }
        textStorage.endEditing()
        setNeedsRecolor()
    }

    // Everything below is cached per paragraph text, so only edited paragraphs are re-analysed.
    private struct ParagraphMarks {
        var markdown: [(NSRange, Markdown.Kind)]
        var partsOfSpeech: [(NSRange, PartOfSpeech)]?
        var style: [NSRange]?
    }

    private func marks(for text: String) -> ParagraphMarks {
        var marks = paragraphCache[text] ?? ParagraphMarks(markdown: Markdown.spans(in: text, range: NSRange(location: 0, length: (text as NSString).length)))
        let needsPOS = !syntaxMask.isEmpty && marks.partsOfSpeech == nil
        let needsStyle = !styleMask.isEmpty && marks.style == nil
        if needsPOS || needsStyle {
            let language = Linguistics.language(of: text)
            let excluded = marks.markdown.filter { Markdown.unchecked.contains($0.1) }.map(\.0)
            let tokens = Linguistics.tokens(in: text, language: language)
            if needsPOS {
                marks.partsOfSpeech = Linguistics.partsOfSpeech(tokens)
                    .filter { pos in !excluded.contains { NSIntersectionRange($0, pos.0).length > 0 } }
            }
            if needsStyle {
                marks.style = StyleCheck.shared.check(text, categories: styleMask, language: language?.rawValue,
                                                      excluded: excluded, tokens: tokens)
            }
        }
        if paragraphCache.count > 5000 { paragraphCache.removeAll() }
        paragraphCache[text] = marks
        return marks
    }

    // Colors go in temporary attributes so they never touch the document or undo.
    // Only the paragraphs on screen are colored; scrolling recolors.
    // Typing triggers both a text change and a selection change; color once per run-loop pass.
    private var recolorPending = false
    private var caretLine = -1
    private func setNeedsRecolor() {
        guard !recolorPending else { return }
        recolorPending = true
        DispatchQueue.main.async { [weak self] in
            self?.recolorPending = false
            self?.recolor()
        }
    }

    func recolor() {
        guard let layoutManager, let textContainer, let scrollView = enclosingScrollView else { return }
        let ns = string as NSString
        var visibleRect = scrollView.contentView.bounds
        visibleRect.origin.y -= textContainerOrigin.y
        let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: visibleRect, in: textContainer)
        let visible = ns.paragraphRange(for: layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        let focus = focusMode ? focusRange() : nil
        let isFocused = { (r: NSRange) in focus.map { NSIntersectionRange(r, $0).length == r.length } ?? true }

        for key: NSAttributedString.Key in [.foregroundColor, .strikethroughStyle, .underlineStyle, .underlineColor] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: visible)
        }
        let single = NSUnderlineStyle.single.rawValue
        var inlineCode: [NSRange] = [], highlights: [NSRange] = [], grey: [NSRange] = [], emphasisMarks: [NSRange] = []
        var headingLabels: [EditorLayoutManager.HeadingLabel] = []
        let caret = selectedRange()
        let marksOn = Settings.cjkEmphasis == .marks
        let blocks = codeBlocks.filter { NSIntersectionRange($0, visible).length > 0 }

        ns.enumerateSubstrings(in: visible, options: [.byParagraphs]) { text, range, _, _ in
            guard let text, !text.isEmpty, !blocks.contains(where: { NSIntersectionRange($0, range).length == range.length }) else { return }
            let marks = self.marks(for: text)
            let shift = { (r: NSRange) in NSRange(location: r.location + range.location, length: r.length) }
            for (span, pos) in marks.partsOfSpeech ?? [] {
                guard let (_, color) = Theme.partOfSpeech.first(where: { self.syntaxMask.contains($0.0) && $0.0 == pos }) else { continue }
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: shift(span))
            }
            for span in marks.style ?? [] {
                layoutManager.addTemporaryAttributes([.foregroundColor: Theme.syntax, .strikethroughStyle: single], forCharacterRange: shift(span))
            }
            for (span, kind) in marks.markdown {
                let span = shift(span)
                switch kind {
                case .syntax:
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.syntax, forCharacterRange: span)
                    grey.append(span)
                case .url:
                    layoutManager.addTemporaryAttributes([.foregroundColor: Theme.syntax, .underlineStyle: single, .underlineColor: Theme.url], forCharacterRange: span)
                    grey.append(span)
                case .autolink:
                    layoutManager.addTemporaryAttributes([.underlineStyle: single, .underlineColor: Theme.url], forCharacterRange: span)
                case .hashtag:
                    layoutManager.addTemporaryAttributes([.underlineStyle: single, .underlineColor: Theme.syntax], forCharacterRange: span)
                case .strike:
                    layoutManager.addTemporaryAttribute(.strikethroughStyle, value: single, forCharacterRange: span)
                case .taskDone:
                    layoutManager.addTemporaryAttributes([.foregroundColor: Theme.syntax, .strikethroughStyle: single], forCharacterRange: span)
                    grey.append(span)
                case .highlight:
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.highlightText, forCharacterRange: span)
                    highlights.append(span)
                case .code:
                    inlineCode.append(span)
                case .emphasis where marksOn:
                    Markdown.emphasisMarked.enumerateMatches(in: self.string, range: span) { m, _, _ in
                        if let m { emphasisMarks.append(m.range) }
                    }
                case .heading:
                    // The "## " marks in the syntax grey (the palette's with a palette), like other Markdown marks.
                    let hashes = NSRange(location: span.location, length: Markdown.hangingMarkerLength(in: self.string, paragraph: span))
                    // Off the caret's line they show as a small "H2" instead (Draft addition); on it, the marks to edit.
                    let onCaretLine = caret.location >= span.location && caret.location <= NSMaxRange(span)
                        || NSIntersectionRange(caret, span).length > 0
                    if onCaretLine {
                        layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.syntax, forCharacterRange: hashes)
                        grey.append(hashes)
                    } else {
                        let level = (self.string as NSString).substring(with: hashes).filter { $0 == "#" }.count
                        layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: hashes)
                        headingLabels.append(.init(range: NSRange(location: hashes.location, length: level), level: level,
                                                   color: isFocused(span) ? Theme.text.withAlphaComponent(0.8) : Theme.focusDimSyntax))
                    }
                case .strong, .emphasis:
                    break
                }
            }
        }
        if let focus {
            for outside in [NSRange(location: visible.location, length: max(0, focus.location - visible.location)),
                            NSRange(location: NSMaxRange(focus), length: max(0, NSMaxRange(visible) - NSMaxRange(focus)))]
                where outside.length > 0 {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.focusDim, forCharacterRange: outside)
            }
            for span in grey where !isFocused(span) {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.focusDimSyntax, forCharacterRange: span)
            }
        }
        // Dimming recoloured everything outside the focus; hidden heading marks stay hidden under their "H2".
        for label in headingLabels {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: label.range)
        }
        if let editorLayoutManager {
            editorLayoutManager.inlineCode = inlineCode
            editorLayoutManager.highlights = highlights
            editorLayoutManager.codeBlocks = blocks
            editorLayoutManager.emphasisMarks = emphasisMarks
            editorLayoutManager.headingLabels = headingLabels
            setNeedsDisplay(visibleRect)
        }
    }

    // The sentence or paragraph containing the caret; nil when nothing is dimmed.
    private func focusRange() -> NSRange? {
        guard focusScope != .typewriter else { return nil }
        let ns = string as NSString
        // A selection keeps its paragraphs in full colour.
        let selection = NSIntersectionRange(selectedRange(), NSRange(location: 0, length: ns.length))
        if selection.length > 0 { return ns.paragraphRange(for: selection) }
        let caret = min(selectedRange().location, ns.length)
        let paragraph = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        guard focusScope == .sentence else { return paragraph }
        var found: NSRange?
        ns.enumerateSubstrings(in: paragraph, options: [.bySentences, .substringNotRequired]) { _, _, enclosing, stop in
            if caret >= enclosing.location && caret <= NSMaxRange(enclosing) {
                found = enclosing
                stop.pointee = true
            }
        }
        return found ?? paragraph
    }

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        pendingEdit = NSRange(location: range.location, length: (replacementString as NSString?)?.length ?? 0)
        return super.shouldChangeText(in: range, replacementString: replacementString)
    }

    override func didChangeText() {
        super.didChangeText()
        let blocks = Markdown.codeBlocks(in: string)
        let blocksChanged = blocks != codeBlocks
        codeBlocks = blocks
        // Setting attributes during 注音 composition would wipe the marked-text underline.
        guard !hasMarkedText() else { setNeedsRecolor(); return }
        if blocksChanged {
            applyStyles(in: NSRange(location: 0, length: (string as NSString).length))
        } else if let edit = pendingEdit {
            applyStyles(in: edit)
        }
        pendingEdit = nil
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Moving to another line swaps a heading's "H2" and its "##".
        // The selection can point past the text mid-replacement (loading another document); clamp it.
        let ns = string as NSString
        let line = ns.paragraphRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0)).location
        if line != caretLine {
            caretLine = line
            if restyled { setNeedsRecolor() }
        }
        if focusMode && restyled {
            setNeedsRecolor()
            if !stillSelecting && typewriter != nil { centerCaret(animated: true) }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        relayout()  // weight is 20 lighter in dark mode
    }

    // MARK: - Editing (iA's Markdown-aware keys, docs/markdown-styling.md)

    private static let lineMarker = try! NSRegularExpression(pattern: #"^([ \t]*)(?:([-*+])|(\d+)\.)([ \t]+)(\[[ xX]\][ \t]+)?|^((?:>[ \t]?)+)"#)
    private static let pairs: [String: String] = ["(": ")", "[": "]", "{": "}"]

    private var ns: NSString { string as NSString }

    private func replace(_ range: NSRange, with text: String, caret: Int? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: caret ?? range.location + (text as NSString).length, length: 0))
    }

    // Inside a code block the Markdown-aware keys stay out of the way.
    private var caretInCodeBlock: Bool {
        let caret = selectedRange().location
        return codeBlocks.contains { caret >= $0.location && caret <= NSMaxRange($0) }
    }

    private func currentLine() -> NSRange {
        let line = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let end = NSMaxRange(line) > line.location && ns.character(at: NSMaxRange(line) - 1) == 10 ? NSMaxRange(line) - 1 : NSMaxRange(line)
        return NSRange(location: line.location, length: end - line.location)
    }

    override func insertNewline(_ sender: Any?) {
        let caret = selectedRange()
        guard caret.length == 0, !hasMarkedText() else { return super.insertNewline(sender) }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            return replace(caret, with: "\\\n")                      // hard break
        }
        let line = currentLine()
        if caretInCodeBlock {
            let indent = ns.substring(with: line).prefix { $0 == " " || $0 == "\t" }
            return replace(caret, with: "\n" + indent)
        }
        // Enter right before a closing inline marker steps over it.
        let paragraph = ns.substring(with: line)
        for (span, kind) in Markdown.spans(in: paragraph, range: NSRange(location: 0, length: (paragraph as NSString).length)) {
            let closer: Int
            switch kind {
            case .strong, .strike, .highlight: closer = 2
            case .emphasis: closer = 1
            case .code: closer = (paragraph as NSString).substring(with: span).prefix { $0 == "`" }.count
            default: continue
            }
            if line.location + NSMaxRange(span) - closer == caret.location {
                return setSelectedRange(NSRange(location: line.location + NSMaxRange(span), length: 0))
            }
        }
        guard !Markdown.isHorizontalRule(string, line: line), let match = Self.lineMarker.firstMatch(in: string, range: line) else {
            let indent = paragraph.prefix { $0 == " " || $0 == "\t" }
            return replace(caret, with: "\n" + indent)
        }
        if match.range.length == line.length {
            return replace(line, with: "")                              // empty item ends the list
        }
        let part = { (i: Int) in match.range(at: i).location == NSNotFound ? "" : self.ns.substring(with: match.range(at: i)) }
        var marker: String
        if match.range(at: 6).location != NSNotFound {
            marker = part(6)
        } else {
            let bullet = match.range(at: 3).location != NSNotFound ? "\((Int(part(3)) ?? 0) + 1)." : part(2)
            marker = part(1) + bullet + part(4) + (part(5).isEmpty ? "" : "[ ]" + part(5).dropFirst(3))
        }
        replace(caret, with: "\n" + marker)
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { return super.insertTab(sender) }
        indentLines(by: 1)
    }

    override func insertBacktab(_ sender: Any?) { indentLines(by: -1) }

    override func insertTabIgnoringFieldEditor(_ sender: Any?) { insertText("\t", replacementRange: selectedRange()) }

    // Tab indents every selected line; on quote lines it adds or removes a `>` level instead.
    private func indentLines(by delta: Int) {
        let selection = selectedRange()
        let lines = ns.lineRange(for: selection)
        var result = ""
        var firstShift = 0
        ns.enumerateSubstrings(in: lines, options: [.byLines]) { line, _, _, _ in
            var line = line ?? ""
            let before = line.count
            if line.hasPrefix(">") {
                line = delta > 0 ? ">" + (line.hasPrefix("> ") ? "" : " ") + line : String(line.dropFirst(line.hasPrefix(">>") || !line.hasPrefix("> ") ? 1 : 2))
            } else if delta > 0 {
                line = "\t" + line
            } else if line.hasPrefix("\t") {
                line.removeFirst()
            } else {
                line.removeFirst(min(4, line.prefix { $0 == " " }.count))
            }
            if result.isEmpty { firstShift = line.count - before }
            result += line + "\n"
        }
        if NSMaxRange(lines) == ns.length && !ns.substring(with: lines).hasSuffix("\n") { result.removeLast() }
        guard shouldChangeText(in: lines, replacementString: result) else { return }
        textStorage?.replaceCharacters(in: lines, with: result)
        didChangeText()
        if selection.length == 0 {
            setSelectedRange(NSRange(location: max(lines.location, selection.location + firstShift), length: 0))
        } else {
            setSelectedRange(NSRange(location: lines.location, length: (result as NSString).length))
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        guard caret.length == 0, !hasMarkedText(), caret.location > 0 else { return super.deleteBackward(sender) }
        guard !caretInCodeBlock else { return super.deleteBackward(sender) }
        let line = currentLine()
        let leading = ns.substring(with: line).prefix { $0 == " " || $0 == "\t" }
        let offset = caret.location - line.location
        // Backspace at the end of leading whitespace outdents.
        if offset > 0 && offset == (leading as Substring).utf16.count { return indentLines(by: -1) }
        // Right after an inline opener or closer, the whole formatting pair goes.
        let text = ns.substring(with: line)
        for (span, kind) in Markdown.spans(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let marker: Int
            switch kind {
            case .strong, .strike, .highlight: marker = 2
            case .emphasis: marker = 1
            case .code: marker = (text as NSString).substring(with: span).prefix { $0 == "`" }.count
            default: continue
            }
            let start = line.location + span.location, end = line.location + NSMaxRange(span)
            guard span.length > 2 * marker, offset > 0, caret.location == start + marker || caret.location == end else { continue }
            let whole = NSRange(location: start, length: span.length)
            let inner = ns.substring(with: NSRange(location: start + marker, length: span.length - 2 * marker))
            return replace(whole, with: inner, caret: caret.location == end ? start + (inner as NSString).length : start)
        }
        // A line holding only a marker loses the whole marker.
        if let match = Self.lineMarker.firstMatch(in: string, range: line),
           match.range.length == line.length, NSMaxRange(match.range) == caret.location {
            return replace(line, with: String(leading))
        }
        super.deleteBackward(sender)
    }

    // The input method's clause underlines carry their own (blue) colour; recolour them to the caret's.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let marked = string as? NSAttributedString else {
            return super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
        let recoloured = NSMutableAttributedString(attributedString: marked)
        let all = NSRange(location: 0, length: recoloured.length)
        recoloured.enumerateAttribute(.underlineStyle, in: all) { style, range, _ in
            recoloured.addAttribute(.underlineColor, value: Theme.markedUnderline, range: range)
            if style == nil { recoloured.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
        super.setMarkedText(recoloured, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    // Auto-pairing for ( [ { only: wrap a selection, insert a pair, or type over the closer.
    override func insertText(_ text: Any, replacementRange: NSRange) {
        guard let typed = text as? String, replacementRange.location == NSNotFound, !hasMarkedText() else {
            return super.insertText(text, replacementRange: replacementRange)
        }
        let selection = selectedRange()
        if let closer = Self.pairs[typed] {
            let inner = ns.substring(with: selection)
            return replace(selection, with: typed + inner + closer, caret: selection.location + 1 + (inner as NSString).length)
        }
        if Self.pairs.values.contains(typed), selection.length == 0, selection.location < ns.length,
           ns.substring(with: NSRange(location: selection.location, length: 1)) == typed {
            return setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        }
        super.insertText(text, replacementRange: replacementRange)
    }

    // MARK: - Typewriter

    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        if let f = typewriter, f != 0.5, let scrollView = enclosingScrollView {
            origin.y = ceil(scrollView.contentSize.height * f - typography.lineHeight / 2) - 3
        }
        return origin
    }

    private var scrollTarget: NSPoint?
    private var scrollTargetTime: CFTimeInterval = 0

    private func centerCaret(animated: Bool) {
        guard let layoutManager, let textContainer, let scrollView = enclosingScrollView else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(selectedRange().location + 1, (string as NSString).length)))
        let location = selectedRange().location
        var line: NSRect
        if location >= (string as NSString).length && !layoutManager.extraLineFragmentRect.isEmpty {
            line = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, max((string as NSString).length - 1, 0)))
            line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        line.origin.y += textContainerOrigin.y
        let origin = NSPoint(x: 0, y: max(0, line.midY - scrollView.contentSize.height * (typewriter ?? 0.5)))
        // A click asks twice (selection change, then scrollRangeToVisible); one animation per target.
        if animated && origin == scrollTarget && CACurrentMediaTime() - scrollTargetTime < 0.3 { return }
        scrollTarget = origin
        scrollTargetTime = CACurrentMediaTime()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(origin)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        if typewriter != nil { centerCaret(animated: true) } else { super.scrollRangeToVisible(range) }
    }

    // MARK: - Paper

    override func draw(_ dirtyRect: NSRect) {
        let paper = Settings.paper
        if paper != .none {
            let palette = Palette.current
            let opacity = CGFloat(Settings.paperOpacity)
            let line = (palette?.paperLine ?? Theme.syntax).withAlphaComponent((palette == nil ? 0.35 : 1) * opacity)
            let margin = (palette?.margin ?? Theme.caret).withAlphaComponent((palette == nil ? 0.45 : 1) * opacity)
            // In the gap between a heading's "### " and the text, 0.8 en before where the text starts.
            let left = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) + typography.en * (typography.marginChars - 0.8)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                paper.draw(in: dirtyRect, top: textContainerOrigin.y, pitch: typography.lineHeight, left: left,
                           line: line, margin: margin)
            }
        }
        super.draw(dirtyRect)
    }

    // MARK: - Caret

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: caretRect(rect), color: color, turnedOn: flag)
    }

    private func caretRect(_ rect: NSRect) -> NSRect {
        guard rect.width <= 1.5 else { return rect }
        var r = rect.insetBy(dx: 0, dy: 1)
        let width = typography.caretWidth(forHeight: r.height)
        r.origin.x -= width > 3 ? width - 3 : width == 3 ? 1 : 0
        r.size.width = width
        return r
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.insetBy(dx: -3, dy: 0), avoidAdditionalLayout: flag)
    }

    // MARK: - Actions

    @objc func toggleFocusMode(_ sender: Any?) {
        UserDefaults.standard.set(!focusMode, forKey: "FocusMode")
        NotificationCenter.default.post(name: Self.focusModeDidChange, object: nil)
    }

    @objc func selectTypewriterPosition(_ sender: NSMenuItem) {
        typewriterPosition = TypewriterPosition(rawValue: sender.tag) ?? .center
        UserDefaults.standard.set(typewriterPosition.rawValue, forKey: "TypewriterPosition")
        relayout()
    }

    @objc func selectFocusScope(_ sender: NSMenuItem) {
        focusScope = FocusScope(rawValue: sender.tag) ?? .sentence
        UserDefaults.standard.set(focusScope.rawValue, forKey: "FocusScope")
        recolor()
    }

    // As in iA: the main item turns everything off, or restores the last used set.
    @objc func toggleSyntaxControl(_ sender: Any?) {
        let last = UserDefaults.standard.object(forKey: "LastSyntaxControl") as? Int ?? PartOfSpeech.all.rawValue
        setSyntax(syntaxMask.isEmpty ? PartOfSpeech(rawValue: last) : [])
    }

    @objc func toggleSyntaxTarget(_ sender: NSMenuItem) {
        setSyntax(syntaxMask.symmetricDifference(PartOfSpeech(rawValue: sender.tag)))
    }

    private func setSyntax(_ mask: PartOfSpeech) {
        syntaxMask = mask
        UserDefaults.standard.set(mask.rawValue, forKey: "SyntaxControl")
        if !mask.isEmpty { UserDefaults.standard.set(mask.rawValue, forKey: "LastSyntaxControl") }
        recolor()
    }

    @objc func toggleStyleCheck(_ sender: Any?) {
        let last = UserDefaults.standard.object(forKey: "LastStyleCheck") as? Int ?? StyleCategory.all.rawValue
        setStyle(styleMask.isEmpty ? StyleCategory(rawValue: last) : [])
    }

    @objc func toggleStyleTarget(_ sender: NSMenuItem) {
        setStyle(styleMask.symmetricDifference(StyleCategory(rawValue: sender.tag)))
    }

    private func setStyle(_ mask: StyleCategory) {
        styleMask = mask
        UserDefaults.standard.set(mask.rawValue, forKey: "StyleCheck")
        if !mask.isEmpty { UserDefaults.standard.set(mask.rawValue, forKey: "LastStyleCheck") }
        for key in paragraphCache.keys { paragraphCache[key]?.style = nil }  // results depend on the categories
        recolor()
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleFocusMode(_:)):
            item.title = L(focusMode ? "Disable Focus Mode" : "Enable Focus Mode")
        case #selector(selectTypewriterPosition(_:)):
            item.state = typewriterPosition.rawValue == item.tag ? .on : .off
        case #selector(selectFocusScope(_:)):
            item.state = focusScope.rawValue == item.tag ? .on : .off
        case #selector(toggleSyntaxControl(_:)):
            item.title = L(syntaxMask.isEmpty ? "Show Syntax" : "Hide Syntax")
        case #selector(toggleSyntaxTarget(_:)):
            item.state = syntaxMask.contains(PartOfSpeech(rawValue: item.tag)) ? .on : .off
        case #selector(toggleStyleCheck(_:)):
            item.title = L(styleMask.isEmpty ? "Enable Style Check" : "Disable Style Check")
        case #selector(toggleStyleTarget(_:)):
            item.state = styleMask.contains(StyleCategory(rawValue: item.tag)) ? .on : .off
        default: break
        }
        return super.validateMenuItem(item)
    }
}
