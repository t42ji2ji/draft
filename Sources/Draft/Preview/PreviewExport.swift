import AppKit
import UniformTypeIdentifiers

// File > Export… (HTML, PDF), File > Print…, Edit > Copy HTML, and the PDF display mode, all from the preview's page.
// iA also exports Word (.docx), and from its MultiMarkdown core ODT/LaTeX/OPML; those are not implemented (docs/preview.md §7).
extension PreviewViewController {
    enum ExportFormat: Int, CaseIterable { case html, pdf
        var title: String { self == .html ? "HTML" : "PDF" }
        var type: UTType { self == .html ? .html : .pdf }
    }

    /// ⇧⌘E Export…: save panel with a format pop-up, run as a sheet on `window`.
    @objc func exportDocument(_ sender: Any?) {
        let panel = NSSavePanel()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 26), pullsDown: false)
        ExportFormat.allCases.forEach { popup.addItem(withTitle: $0.title) }
        popup.selectItem(at: UserDefaults.standard.integer(forKey: "PreviewExportFormat"))
        let label = NSTextField(labelWithString: L("Format:"))
        let accessory = NSStackView(views: [label, popup])
        accessory.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = accessory
        let base = (exportDocumentURL?.deletingPathExtension().lastPathComponent).flatMap { $0.isEmpty ? nil : $0 } ?? L("Untitled")
        func apply() {
            let f = ExportFormat(rawValue: popup.indexOfSelectedItem) ?? .html
            panel.allowedContentTypes = [f.type]
            panel.nameFieldStringValue = base + "." + (f.type.preferredFilenameExtension ?? "")
        }
        apply()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: popup.menu, queue: .main) { _ in apply() }
        if let dir = exportDocumentURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            NotificationCenter.default.removeObserver(observer)
            guard response == .OK, let url = panel.url, let self else { return }
            let f = ExportFormat(rawValue: popup.indexOfSelectedItem) ?? .html
            UserDefaults.standard.set(f.rawValue, forKey: "PreviewExportFormat")
            let finish: (Error?) -> Void = { error in if let error { NSAlert(error: error).runModal() } }
            if f == .html { self.exportHTML(to: url, completion: finish) } else { self.exportPDF(to: url, completion: finish) }
        }
        if let window = view.window ?? NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    // MARK: HTML

    /// A standalone HTML file: the rendered page (`document.documentElement.outerHTML`, as iA reads it) with the
    /// template's stylesheets inlined. Fonts fall back to `local()` sources; images keep paths relative to the document.
    func exportHTML(to url: URL, completion: @escaping (Error?) -> Void) {
        standaloneHTML { html in
            do { try html.write(to: url, atomically: true, encoding: .utf8); completion(nil) } catch { completion(error) }
        }
    }

    func standaloneHTML(_ completion: @escaping (String) -> Void) {
        whenRendered { [self] in
            exportWebView.evaluateJavaScript("document.documentElement.outerHTML") { [self] result, _ in
                var html = (result as? String) ?? ""
                let dir = template.directory
                html = html.replacingOccurrences(of: #"<link rel="stylesheet" media="all" href="([^"]+)">"#, with: "\u{1}$1\u{1}", options: .regularExpression)
                while let r = html.range(of: "\u{1}[^\u{1}]+\u{1}", options: .regularExpression) {
                    let file = String(html[r].dropFirst().dropLast())
                    html.replaceSubrange(r, with: "<style>\n" + Self.inlinedCSS(dir.appendingPathComponent(file)) + "</style>")
                }
                html = html.replacingOccurrences(of: #" data-line="\d+""#, with: "", options: .regularExpression)
                // App-only font URLs (also inside the inserted KaTeX sheet) and the window-specific state go.
                html = html.replacingOccurrences(of: #",?\s*url\("?ia-writer-font://[^)"]*"?\)(\s*format\([^)]*\))?"#, with: "", options: .regularExpression)
                html = html.replacingOccurrences(of: " night-mode", with: "")
                html = html.replacingOccurrences(of: #" style="padding-top: [^"]*""#, with: "", options: .regularExpression)
                html = Self.relativizeFileURLs(html, documentFolder: exportDocumentURL?.deletingLastPathComponent())
                completion("<!DOCTYPE html>\n" + html)
            }
        }
    }

    /// The CSS file with its `@import`s expanded and the app-only font URLs removed.
    static func inlinedCSS(_ file: URL, depth: Int = 0) -> String {
        guard depth < 8, var css = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        let importRx = try! NSRegularExpression(pattern: #"@import url\("([^"]+)"\);"#)
        for m in importRx.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
            let name = String(css[Range(m.range(at: 1), in: css)!])
            // font.css imports some files by bare name that live in font/.
            var target = file.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) {
                target = file.deletingLastPathComponent().appendingPathComponent("font/" + name)
            }
            css.replaceSubrange(Range(m.range, in: css)!, with: inlinedCSS(target, depth: depth + 1))
        }
        return css.replacingOccurrences(of: #",\s*url\("ia-writer-font://[^"]*"\)"#, with: "", options: .regularExpression)
    }

    static func relativizeFileURLs(_ html: String, documentFolder: URL?) -> String {
        let rx = try! NSRegularExpression(pattern: PreviewSchemeHandler.fileScheme + #"://([^"]*)"#)
        var out = html
        for m in rx.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            let path = (String(html[Range(m.range(at: 1), in: html)!]).removingPercentEncoding) ?? ""
            var replacement = URL(fileURLWithPath: path).absoluteString
            if let folder = documentFolder?.path, path.hasPrefix(folder + "/") {
                replacement = String(path.dropFirst(folder.count + 1)).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? replacement
            }
            out.replaceSubrange(Range(m.range, in: out)!, with: replacement)
        }
        return out
    }

    /// ⇧⌘C Copy HTML: the document body as HTML (no template).
    @objc func copyHTML(_ sender: Any?) {
        var renderer = PreviewRenderer(baseURL: exportDocumentURL?.deletingLastPathComponent())
        renderer.sourceLines = false
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(renderer.render(exportText), forType: .string)
    }

    // MARK: PDF and print

    /// Print settings shared by PDF and print: the template's header/footer heights become the top/bottom margins.
    func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = max(template.headerHeight, 36)
        info.bottomMargin = max(template.footerHeight, 36)
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        return info
    }

    func exportPDF(to url: URL, completion: @escaping (Error?) -> Void) {
        makePDF { data in
            guard let data else { return completion(CocoaError(.fileWriteUnknown)) }
            do { try data.write(to: url); completion(nil) } catch { completion(error) }
        }
    }

    /// Paginated PDF of the page, laid out by WebKit's print path (the template's `@media print` rules apply).
    func makePDF(_ completion: @escaping (Data?) -> Void) {
        whenRendered { [self] in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            let info = printInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tmp
            let op = exportWebView.printOperation(with: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            op.view?.frame = exportWebView.view.bounds
            printing = true
            // WKWebView only paginates through the asynchronous modal path; `run()` spins forever.
            let delegate = PrintDone { [self] ok in
                printing = false
                completion(ok ? try? Data(contentsOf: tmp) : nil)
                try? FileManager.default.removeItem(at: tmp)
            }
            op.runModal(for: view.window ?? NSWindow(), delegate: delegate,
                        didRun: #selector(PrintDone.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    /// ⌘P Print…
    @objc func printPreview(_ sender: Any?) {
        whenRendered { [self] in
            let op = exportWebView.printOperation(with: printInfo())
            op.view?.frame = exportWebView.view.bounds
            printing = true
            let delegate = PrintDone { [self] _ in printing = false }
            op.runModal(for: view.window ?? NSApp.keyWindow ?? NSWindow(), delegate: delegate,
                        didRun: #selector(PrintDone.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }
}

/// Receives NSPrintOperation's didRun callback; keeps itself alive until then.
private final class PrintDone: NSObject {
    private static var live: Set<PrintDone> = []
    private let done: (Bool) -> Void
    init(_ done: @escaping (Bool) -> Void) {
        self.done = done
        super.init()
        Self.live.insert(self)
    }
    @objc func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        // Called on a print thread; WebKit must be touched on the main thread.
        DispatchQueue.main.async { [self] in
            done(success)
            Self.live.remove(self)
        }
    }
}
