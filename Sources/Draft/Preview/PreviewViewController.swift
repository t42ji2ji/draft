import AppKit
import UniformTypeIdentifiers

// iA Writer's Preview pane (IAPreviewViewController): a web view showing the document through an iA template,
// plus the preview's own bottom bar (Web | PDF, template, Split | Full). See docs/preview.md.
// Nothing here is created until the pane is first shown; `loadView` loads WebKit (WebKitRuntime.swift) and builds the web view.
final class PreviewViewController: NSViewController {
    enum Layout: Int { case full = 0, split = 1 }          // iA `changePreviewWidthTo:` tags: Full none, Split 1
    enum DisplayMode: Int { case web = 0, pdf = 1 }        // iA `changePreviewDisplayModeTo:` tags: Web none, PDF 1

    /// `Resources/Preview` inside the app; the harness points it at the repo.
    static var resourceRoot = Bundle.main.resourceURL!.appendingPathComponent("Preview")

    /// Scroll position of the preview, as a fractional 1-based source line, while the user scrolls it.
    var onScrollToSourceLine: ((Double) -> Void)?
    /// Split / Full clicked in the preview's bottom bar.
    var onChangeLayout: ((Layout) -> Void)?
    /// A link was clicked; default opens it with NSWorkspace. Relative links and wikilinks arrive resolved against the document's folder.
    var onOpenURL: ((URL) -> Void)?

    var layout: Layout = .full { didSet { bar?.update(layout: layout, mode: displayMode) } }
    private(set) var displayMode: DisplayMode = .web

    private var chosenTemplate: PreviewTemplate?
    var template: PreviewTemplate {
        get { chosenTemplate ?? PreviewTemplate.selected }
        set {
            chosenTemplate = newValue
            PreviewTemplate.selected = newValue
            bar?.select(newValue)
            reloadTemplate()
        }
    }

    private var webView: DynamicWebView!
    private var pdfView: NSView?
    private var bar: PreviewBar!
    private var webDelegate: PreviewWebDelegate?
    private var text = ""
    private var documentURL: URL?
    private var pageReady = false
    private var pendingScrollLine: Double?
    private var renderTimer: Timer?
    private var generation = 0
    private var renderedGeneration = -1
    private var renderWaiters: [() -> Void] = []
    private let renderQueue = DispatchQueue(label: "preview.render", qos: .userInitiated)

    /// Delay between the last keystroke and re-rendering (inferred; iA's `_previewUpdateTimer` interval was not extracted).
    static let updateDelay: TimeInterval = 0.15
    /// Space above and below the content, passed to iA's `Template.updateInset`. 24 puts the first line where iA's is
    /// when the pane starts below the toolbar (measured); add the toolbar height if the pane extends under it.
    var inset: CGFloat = 24 { didSet { if pageReady { js("Template.updateInset(\"\(inset)px\")") } } }

    // MARK: - View

    override func loadView() {
        let handler = PreviewSchemeHandler()
        let delegate = PreviewWebDelegate(self)
        webView = DynamicWebView(schemeHandlers: [PreviewSchemeHandler.fontScheme: handler, PreviewSchemeHandler.fileScheme: handler],
                                 messageHandler: delegate, messageName: "draft", navigationDelegate: delegate)
        webDelegate = delegate
        webView.view.setAccessibilityIdentifier("preview")

        bar = PreviewBar()
        // Bar changes dip the page out and back in, instead of showing a blank or half-built page.
        bar.onMode = { [weak self] mode in
            self?.transition { ready in self?.setDisplayMode(mode, ready: ready) }
        }
        bar.onLayout = { [weak self] l in
            self?.transition { ready in self?.layout = l; self?.onChangeLayout?(l); DispatchQueue.main.async(execute: ready) }
        }
        bar.onTemplate = { [weak self] t in
            self?.transition { ready in self?.template = t; self?.whenRendered(ready) }
        }
        bar.select(template)
        bar.update(layout: layout, mode: displayMode)

        let root = PreviewRootView()
        root.onAppearanceChange = { [weak self] in self?.applyClasses() }
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.applyClasses() }
        for v in [webView.view, bar!] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            webView.view.topAnchor.constraint(equalTo: root.topAnchor),
            webView.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.view.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 39),
        ])
        view = root
        reloadTemplate()
    }

    // MARK: - Public API

    /// Pushes the editor's text. Rendering is debounced; call on every text change.
    func update(text: String, documentURL: URL?) {
        self.text = text
        self.documentURL = documentURL
        generation += 1
        guard isViewLoaded else { return }
        renderTimer?.invalidate()
        renderTimer = Timer.scheduledTimer(withTimeInterval: Self.updateDelay, repeats: false) { [weak self] _ in self?.render() }
    }

    /// Renders immediately (use when the pane is first shown or the document changes).
    func updateNow(text: String, documentURL: URL?) {
        self.text = text
        self.documentURL = documentURL
        generation += 1
        _ = view
        renderTimer?.invalidate()
        render()
    }

    /// ⇧⌘R Reload Preview: reloads the template from disk.
    @objc func reloadPreview(_ sender: Any?) { reloadTemplate() }

    /// Scrolls the preview so the given 1-based source line (fractional) is at the top.
    func scroll(toSourceLine line: Double) {
        guard isViewLoaded, pageReady else { pendingScrollLine = line; return }
        webView.evaluateJavaScript("draftScrollToLine(\(line))")
    }

    @objc func changePreviewDisplayModeTo(_ sender: Any?) {
        setDisplayMode(DisplayMode(rawValue: (sender as? NSMenuItem)?.tag ?? 0) ?? .web)
    }

    func setDisplayMode(_ mode: DisplayMode, ready: (() -> Void)? = nil) {
        displayMode = mode
        bar?.update(layout: layout, mode: mode)
        guard isViewLoaded else { ready?(); return }
        if mode == .pdf { showPDF(then: ready) } else { pdfView?.removeFromSuperview(); pdfView = nil; ready?() }
    }

    // Fade the page (web view and PDF) out over 0.12 s, apply `change`, and fade back in over 0.18 s
    // once `change` reports the new content is ready (or after 1.5 s).
    private var transitionToken = 0
    private func transition(_ change: @escaping (_ ready: @escaping () -> Void) -> Void) {
        transitionToken += 1
        let token = transitionToken
        let content = { [weak self] () -> [NSView] in
            guard let self else { return [] }
            return [self.webView.view] + (self.pdfView.map { [$0] } ?? [])
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            content().forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard let self, token == self.transitionToken else { return }
            var shown = false
            let fadeIn = {
                guard !shown, token == self.transitionToken else { return }
                shown = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    content().forEach { $0.animator().alphaValue = 1 }
                }
            }
            content().forEach { $0.alphaValue = 0 }   // before `change`: its `ready` may fire synchronously (PDF → Web)
            change(fadeIn)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: fadeIn)
        })
    }

    // MARK: - Template

    private func reloadTemplate() {
        guard isViewLoaded else { return }
        pageReady = false
        renderedGeneration = -1
        let page = template.documentFile
        webView.loadFileURL(page, allowingReadAccessTo: Self.resourceRoot)
    }

    /// iA's page scripts (Kit.framework resources), injected in this order once the template has loaded.
    private static let kitScript: String = {
        let kit = resourceRoot.appendingPathComponent("Kit")
        return ["diffHTML", "Template", "Numeral", "Math", "SmartTables", "KaTeX", "mhchem", "copy-tex"].compactMap {
            try? String(contentsOf: kit.appendingPathComponent($0 + ".js"), encoding: .utf8)
        }.joined(separator: "\n;\n") + "\n;\n" + bridgeJS + "\n;0"
    }()

    fileprivate func pageDidFinish() {
        pageReady = true
        js(Self.kitScript)
        let mark = (try? String(contentsOf: Self.resourceRoot.appendingPathComponent("Kit/mark.css"), encoding: .utf8)) ?? ""
        let katex = (try? String(contentsOf: Self.resourceRoot.appendingPathComponent("Kit/KaTeX.css"), encoding: .utf8)) ?? ""
        let sheets: [[String: String]] = [["id": "KaTeX", "style": katex], ["id": "mark", "style": mark]]
        js("Template.insertStylesheets(\"\(Self.encode(sheets))\")")
        js("Template.updateLang(\"\(Self.encode([Self.documentLanguage]))\")")
        js("Template.updateInset(\"\(inset)px\")")
        applyClasses()
        render()
    }

    /// Printing and PDF use the light classes, as iA's PDF mode does.
    var printing = false {
        didSet {
            applyClasses()
            if pageReady { js("Template.updateInset(\"\(printing ? 0 : inset)px\")") }
        }
    }

    private func applyClasses() {
        func redraw(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(redraw) }
        redraw(bar)   // its colours follow the palette
        guard pageReady else { return }
        let dark = !printing && view.effectiveAppearance.isDarkPreview
        js("Template.updateClass(\"\(Self.encode(Self.htmlClasses(dark: dark)))\")")
        // A Draft palette recolours the page (not when printing, which stays light like iA's).
        let paletteCSS = Palette.current.flatMap { printing ? nil : $0 }.map {
            "html, body { background-color: \($0.bg.cssHex) !important; } html, body, html a { color: \($0.text.cssHex) !important; }"
                + " pre, code, kbd { background-color: \($0.chrome.cssHex) !important; }"
                + " blockquote { color: \($0.hashtag.cssHex) !important; border-left-color: \($0.paperLine.cssHex) !important; }"
                + " hr, table, caption, th, td { border-color: \($0.paperLine.cssHex) !important; }"
        } ?? ""
        // The page's scroll bar like the app's ThinScroller: a thin rounded thumb in the syntax grey, no track.
        var thumb = ""
        view.effectiveAppearance.performAsCurrentDrawingAppearance { thumb = Theme.syntax.cssHex }
        let scrollbar = printing ? "" : " ::-webkit-scrollbar { width: 10px; background: transparent; }"
            + " ::-webkit-scrollbar-track { background: transparent; }"
            + " ::-webkit-scrollbar-thumb { background-color: \(thumb)99; border-radius: 5px; border: 3px solid transparent; background-clip: content-box; }"
        let css = paletteCSS + scrollbar
        js("(function(){var s=document.getElementById('draft-palette');if(!s){s=document.createElement('style');s.id='draft-palette';document.head.appendChild(s);}s.textContent=JSON.parse(decodeURIComponent(\"\(Self.encode([css]))\"))[0];})()")
    }

    /// Classes on `<html>` (Kit's list: night-mode, center-headings, number-headings, indent-paragraphs, macos-device,
    /// content-size-*). Values are iA's defaults as seen in its preview; `mac` is what the templates' CSS keys on.
    static func htmlClasses(dark: Bool) -> [String] {
        var c = ["mac", "macos-device", "center-headings",
                 Settings.cjkEmphasis == .marks ? "emphasis-mark" : "emphasis-italic",
                 "content-size-" + Settings.size.name.lowercased(), Settings.highlight.cssClass]
        if dark { c.append("night-mode") }
        return c
    }

    /// `html lang`: iA's templates pick fonts by `x-default-<script>` from the user's languages (inferred mapping).
    static let documentLanguage: String = {
        for lang in Locale.preferredLanguages {
            if lang.hasPrefix("zh-Hant-HK") || lang.hasPrefix("zh-HK") || lang.hasPrefix("zh-Hant-MO") { return "x-default-zh-Hant-HK" }
            if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-TW") { return "x-default-zh-Hant" }
            if lang.hasPrefix("zh") { return "x-default-zh-Hans" }
            if lang.hasPrefix("ja") { return "x-default-ja" }
            if lang.hasPrefix("ko") { return "x-default-ko" }
        }
        return "x-default"
    }()

    // MARK: - Rendering

    private func render() {
        guard pageReady else { return }
        let gen = generation, source = text
        var renderer = PreviewRenderer(baseURL: documentURL?.deletingLastPathComponent())
        renderer.imageURL = { PreviewSchemeHandler.fileURL(for: $0, base: $1) }
        renderQueue.async { [weak self] in
            let html = renderer.render(source)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                let data = Self.encode(["document": html])
                let options = Self.encode(["useDiffHTML": true])
                self.webView.evaluateJavaScript("Template.updateContent(\"\(data)\", \"\(options)\"); Template.updateMath(); Template.updateSmartTables(); draftContentDidChange()") { _, _ in
                    self.renderedGeneration = gen
                    if let line = self.pendingScrollLine { self.pendingScrollLine = nil; self.scroll(toSourceLine: line) }
                    let waiters = self.renderWaiters
                    self.renderWaiters = []
                    waiters.forEach { $0() }
                    if self.displayMode == .pdf { self.showPDF() }
                }
            }
        }
    }

    /// Calls `body` once the current text is on screen.
    func whenRendered(_ body: @escaping () -> Void) {
        _ = view
        if pageReady, renderedGeneration == generation { body() } else { renderWaiters.append(body) }
    }

    private func js(_ s: String) { webView.evaluateJavaScript(s) }

    /// iA's Template.js expects `encodeURIComponent(JSON)`.
    static func encode(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    // MARK: - Scroll sync and links

    fileprivate func didReceive(message body: Any) {
        guard let body = body as? [String: Any] else { return }
        if body["type"] as? String == "scroll", let line = body["line"] as? Double { onScrollToSourceLine?(line) }
    }

    /// Link clicks are handled here and never navigate the page away from the template. Returns whether to allow.
    fileprivate func shouldAllow(navigationType: Int, url: URL?) -> Bool {
        guard navigationType == 0 /* WKNavigationTypeLinkActivated */, let url else { return true }
        if url.scheme == "file" || url.scheme == PreviewSchemeHandler.fileScheme, url.fragment != nil,
           url.path == webView.url?.path || url.scheme == PreviewSchemeHandler.fileScheme && url.path.isEmpty {
            js("draftScrollToAnchor(\(Self.jsString(url.fragment!)))"); return false
        }
        var target = url
        if url.scheme == "file", let documentURL, url.path.hasPrefix(template.directory.path) {
            // A relative link (or wikilink) resolved against the template; re-resolve against the document.
            let relative = String(url.path.dropFirst(template.directory.path.count + 1))
            target = documentURL.deletingLastPathComponent().appendingPathComponent(relative)
        }
        if let onOpenURL { onOpenURL(target) } else { NSWorkspace.shared.open(target) }
        return false
    }

    static func jsString(_ s: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description
    }

    // Scroll sync: top-level blocks carry `data-line`; positions between blocks are interpolated.
    private static let bridgeJS = #"""
    // Template.js calls diffHTML's `innerHTML` as a global; the UMD bundle exports it on `diff`.
    if (typeof innerHTML === 'undefined' && window.diff) { window.innerHTML = window.diff.innerHTML; }
    (function () {
      var programmatic = 0;
      function blocks() { return Array.prototype.filter.call(document.querySelectorAll('[data-line]'), function (e) { return e.offsetParent !== null || e.getClientRects().length; }); }
      function inset() { return parseFloat(getComputedStyle(document.documentElement).paddingTop) || 0; }
      function top(e) { return e.getBoundingClientRect().top + window.scrollY; }
      window.draftScrollToLine = function (line) {
        var b = blocks(); if (!b.length) return;
        var y = 0, i = 0;
        while (i + 1 < b.length && +b[i + 1].dataset.line <= line) i++;
        var l0 = +b[i].dataset.line, y0 = top(b[i]);
        if (line < l0) { y = y0 * (line - 1) / Math.max(1, l0 - 1); }
        else if (i + 1 < b.length) { var l1 = +b[i + 1].dataset.line, y1 = top(b[i + 1]); y = y0 + (y1 - y0) * (line - l0) / Math.max(1, l1 - l0); }
        else { var h = b[i].offsetHeight; y = y0 + Math.min(h, h * (line - l0) / 3); }
        programmatic = Date.now();
        window.scrollTo(0, Math.max(0, y - inset()));
      };
      window.draftScrollToAnchor = function (id) {
        var e = document.getElementById(id); if (e) e.scrollIntoView({ behavior: 'smooth', block: 'start' });
      };
      window.draftContentDidChange = function () {};
      window.addEventListener('scroll', function () {
        if (Date.now() - programmatic < 150) return;
        var b = blocks(); if (!b.length) return;
        var y = window.scrollY + inset(), i = 0;
        while (i + 1 < b.length && top(b[i + 1]) <= y) i++;
        var l0 = +b[i].dataset.line, y0 = top(b[i]), line = l0;
        if (i + 1 < b.length) { var y1 = top(b[i + 1]), l1 = +b[i + 1].dataset.line; line = l0 + (l1 - l0) * Math.max(0, y - y0) / Math.max(1, y1 - y0); }
        window.webkit.messageHandlers.draft.postMessage({ type: 'scroll', line: line });
      }, { passive: true });
    })();
    """#

    /// 1-based source line (fractional) at the top of a TextKit 1 text view's visible area, for `scroll(toSourceLine:)`.
    static func topSourceLine(of textView: NSTextView) -> Double {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, textView.string.utf16.count > 0 else { return 1 }
        let y = textView.visibleRect.minY - textView.textContainerOrigin.y
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: tc)
        let ns = textView.string as NSString
        let index = min(lm.characterIndexForGlyph(at: glyph), ns.length)
        let paragraph = ns.paragraphRange(for: NSRange(location: index, length: 0))
        let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil), in: tc)
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: paragraph.location), options: [.byParagraphs, .substringNotRequired]) { _, _, _, _ in line += 1 }
        let within = rect.height > 0 ? min(1, max(0, (y - rect.minY) / rect.height)) : 0
        return Double(line) + Double(within)
    }

    // MARK: - PDF display mode

    private func showPDF(then ready: (() -> Void)? = nil) {
        makePDF { [weak self] data in
            guard let self, self.displayMode == .pdf, let data else { ready?(); return }
            if self.pdfView == nil {
                let pdf = DynamicPDF.makeView()
                pdf.setValue(NSColor(name: nil) { $0.isDarkPreview ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1) }, forKey: "backgroundColor")
                pdf.translatesAutoresizingMaskIntoConstraints = false
                pdf.alphaValue = self.webView.view.alphaValue   // mid-transition it starts as faded as the page
                self.view.addSubview(pdf)
                let web = self.webView.view
                NSLayoutConstraint.activate([
                    pdf.topAnchor.constraint(equalTo: web.topAnchor),
                    pdf.leadingAnchor.constraint(equalTo: web.leadingAnchor),
                    pdf.trailingAnchor.constraint(equalTo: web.trailingAnchor),
                    pdf.bottomAnchor.constraint(equalTo: web.bottomAnchor),
                ])
                self.pdfView = pdf
            }
            DynamicPDF.setDocument(data, on: self.pdfView!)
            ready?()
        }
    }

    // MARK: - Export and print (PreviewExport.swift)

    var exportWebView: DynamicWebView { _ = view; return webView }
    var exportDocumentURL: URL? { documentURL }
    var exportText: String { text }
}

/// WKNavigationDelegate + WKScriptMessageHandler, by selector. Holds the controller weakly
/// (WKUserContentController retains its message handlers).
private final class PreviewWebDelegate: NSObject {
    weak var controller: PreviewViewController?
    init(_ controller: PreviewViewController) { self.controller = controller }

    @objc(webView:didFinishNavigation:) func didFinish(_ webView: AnyObject, navigation: AnyObject?) {
        controller?.pageDidFinish()
    }

    @objc(webView:decidePolicyForNavigationAction:decisionHandler:)
    func decidePolicy(_ webView: AnyObject, action: NSObject, decisionHandler: @escaping @convention(block) (Int) -> Void) {
        let type = action.value(forKey: "navigationType") as? Int ?? -1
        let url = (action.value(forKey: "request") as? URLRequest)?.url
        let allow = controller?.shouldAllow(navigationType: type, url: url) ?? true
        decisionHandler(allow ? 1 : 0)   // WKNavigationActionPolicyAllow / Cancel
    }

    @objc(userContentController:didReceiveScriptMessage:) func didReceive(_ controller: AnyObject, message: NSObject) {
        if let body = message.value(forKey: "body") { self.controller?.didReceive(message: body) }
    }
}

private final class PreviewRootView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

extension NSAppearance {
    var isDarkPreview: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    var cssHex: String {
        let c = usingColorSpace(.sRGB)!
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

// MARK: - Templates

/// An installed `.iatemplate` bundle (Resources/Preview/Templates).
struct PreviewTemplate: Equatable {
    let directory: URL    // …/X.iatemplate/Contents/Resources
    let identifier: String
    let name: String

    var documentFile: URL {
        let info = NSDictionary(contentsOf: directory.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let page = info?["IATemplateDocumentFile"] as? String ?? "document"
        return directory.appendingPathComponent(page + ".html")
    }

    var headerHeight: CGFloat { info["IATemplateHeaderHeight"] as? CGFloat ?? 0 }
    var footerHeight: CGFloat { info["IATemplateFooterHeight"] as? CGFloat ?? 0 }
    private var info: NSDictionary { NSDictionary(contentsOf: directory.deletingLastPathComponent().appendingPathComponent("Info.plist")) ?? [:] }

    /// iA's menu order (Preview > Template), default Modern (Sans).
    static let all: [PreviewTemplate] = {
        let root = PreviewViewController.resourceRoot.appendingPathComponent("Templates")
        return ["Sans", "Serif", "Mono", "Duo", "Quattro", "GitHub"].compactMap { folder in
            let contents = root.appendingPathComponent(folder + ".iatemplate/Contents")
            guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) else { return nil }
            let strings = contents.appendingPathComponent("Resources/en.lproj/InfoPlist.strings")
            let localized = (NSDictionary(contentsOf: strings)?["CFBundleName"] as? String)
            return PreviewTemplate(directory: contents.appendingPathComponent("Resources"),
                                   identifier: info["CFBundleIdentifier"] as? String ?? folder,
                                   name: localized ?? info["CFBundleName"] as? String ?? folder)
        }
    }()

    static var selected: PreviewTemplate {
        get {
            let id = UserDefaults.standard.string(forKey: "PreviewTemplate")
            precondition(!all.isEmpty, "Resources/Preview is missing from the app bundle (build.sh copies it)")
            return all.first { $0.identifier == id } ?? all[0]
        }
        set { UserDefaults.standard.set(newValue.identifier, forKey: "PreviewTemplate") }
    }
}

// MARK: - Resources served to the web view

/// `ia-writer-font://Name.ttf` → the font file (iA's template CSS uses this scheme);
/// `draft-file:///abs/path` → a file next to the document (images, content blocks).
final class PreviewSchemeHandler: NSObject {
    static let fontScheme = "ia-writer-font"
    static let fileScheme = "draft-file"

    static func fileURL(for src: String, base: URL?) -> String {
        if src.contains("://") || src.hasPrefix("data:") || src.hasPrefix("#") { return src }
        let decoded = src.removingPercentEncoding ?? src
        let path = decoded.hasPrefix("/") ? decoded : (base?.appendingPathComponent(decoded).path ?? decoded)
        var c = URLComponents()
        c.scheme = fileScheme
        c.host = ""
        c.path = path
        return c.string ?? src
    }

    // WKURLSchemeHandler, by selector; the task is a WKURLSchemeTask.
    @objc(webView:startURLSchemeTask:) func start(_ webView: AnyObject, task: NSObject) {
        func call(_ sel: String, _ arg: Any? = nil) { _ = task.perform(NSSelectorFromString(sel), with: arg) }
        guard let url = (task.value(forKey: "request") as? URLRequest)?.url, let fileURL = resolve(url),
              let data = try? Data(contentsOf: fileURL) else {
            return call("didFailWithError:", URLError(.fileDoesNotExist) as NSError)
        }
        let type = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Access-Control-Allow-Origin": "*"])!
        call("didReceiveResponse:", response)
        call("didReceiveData:", data as NSData)
        call("didFinish")
    }

    @objc(webView:stopURLSchemeTask:) func stop(_ webView: AnyObject, task: NSObject) {}

    private func resolve(_ url: URL) -> URL? {
        if url.scheme == Self.fileScheme { return URL(fileURLWithPath: url.path) }
        let name = url.host.map { $0 + url.path } ?? url.path
        let resources = PreviewViewController.resourceRoot.deletingLastPathComponent()
        let candidates = [
            PreviewViewController.resourceRoot.appendingPathComponent("Fonts/" + name),
            resources.appendingPathComponent("Fonts/" + name),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

