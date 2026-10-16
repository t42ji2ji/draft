import AppKit

// One plain-text file. Storage behaviour follows iA Writer's IALibraryDocument; see docs/storage.md.
@objc(TextDocument)
final class TextDocument: NSDocument {
    enum LineEnding: String { case lf = "\n", crlf = "\r\n", cr = "\r" }

    static let selectionAttribute = "app.dorara.draft.selectedRange"

    var text = ""
    // Where a never-saved draft will be written. Saved documents use their file's folder.
    var folderURL: URL?
    var encoding: String.Encoding = .utf8
    var hasBOM = false
    var lineEnding = LineEnding.lf
    // nil means "caret at end", as in iA when the xattr is missing.
    var selectedRange: NSRange?
    var lastShown = Date()

    var isUnwritten: Bool { fileURL == nil && folderURL != nil }

    override class var autosavesInPlace: Bool { true }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    private var library: LibraryWindowController? { windowControllers.first as? LibraryWindowController }

    // MARK: - Windows

    override func makeWindowControllers() {
        LibraryWindowController.shared().show(self)
    }

    override func showWindows() {
        if windowControllers.isEmpty { makeWindowControllers() } else { super.showWindows() }
    }

    // MARK: - Naming

    var derivedName: DocumentName.Result { DocumentName.derive(from: currentText) }

    var currentText: String { library?.textView.string ?? text }

    override var displayName: String! {
        get { fileURL == nil ? derivedName.name : super.displayName }
        set { super.displayName = newValue }
    }

    static var pathExtension: String {
        let ext = (UserDefaults.standard.string(forKey: "DocumentPathExtension") ?? "txt").lowercased()
        return ext.range(of: "^[a-z0-9]{1,25}$", options: .regularExpression) != nil ? ext : "txt"
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        fileURL?.pathExtension.nilIfEmpty ?? TextDocument.pathExtension
    }

    // MARK: - Reading

    override func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url)
        try read(from: data, ofType: typeName)
        selectedRange = Self.readSelection(at: url)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        var decoded: String?
        hasBOM = false
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            hasBOM = true
            encoding = .utf8
            decoded = String(data: data.dropFirst(3), encoding: .utf8)
        } else if let s = String(data: data, encoding: .utf8) {
            encoding = .utf8
            decoded = s
        } else {
            var converted: NSString?
            var lossy: ObjCBool = false
            let raw = NSString.stringEncoding(for: data, encodingOptions: [.allowLossyKey: false], convertedString: &converted, usedLossyConversion: &lossy)
            if raw != 0, let converted {
                encoding = String.Encoding(rawValue: raw)
                decoded = converted as String
            }
        }
        guard let decoded else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: L("The text encoding of the contents could not be determined.")])
        }
        if decoded.contains("\r\n") { lineEnding = .crlf } else if decoded.contains("\r") { lineEnding = .cr } else { lineEnding = .lf }
        text = lineEnding == .lf ? decoded : decoded.replacingOccurrences(of: lineEnding.rawValue, with: "\n")
    }

    // MARK: - Writing

    override func data(ofType typeName: String) throws -> Data {
        library?.commit(into: self)
        let out = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        guard var data = out.data(using: encoding) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError)
        }
        if hasBOM && encoding == .utf8 { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return data
    }

    override func fileAttributesToWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                                        originalContentsURL absoluteOriginalContentsURL: URL?) throws -> [String: Any] {
        var attributes = try super.fileAttributesToWrite(to: url, ofType: typeName, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
        attributes[FileAttributeKey.extensionHidden.rawValue] = true
        return attributes
    }

    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                        originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
        if let range = selectedRange { Self.writeSelection(range, at: url) } else { removexattr(url.path, Self.selectionAttribute, 0) }
        LibrarySync.shared.noteSaved(url: url)
    }

    private static func readSelection(at url: URL) -> NSRange? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = getxattr(url.path, selectionAttribute, &buffer, buffer.count, 0, 0)
        guard n > 0, let s = String(bytes: buffer[0..<n], encoding: .utf8) else { return nil }
        let range = NSRangeFromString(s)
        return range.location == NSNotFound || range.location > Int(Int32.max) ? nil : range
    }

    private static func writeSelection(_ range: NSRange, at url: URL) {
        let bytes = Array(NSStringFromRange(range).utf8)
        setxattr(url.path, selectionAttribute, bytes, bytes.count, 0, 0)
    }

    // MARK: - Drafts: no save panel, no Autosave Information copy

    // The file a draft is written to: `folder/<derived name>.<ext>`, numbered on collision.
    private func draftURL() -> URL? {
        guard let folderURL else { return nil }
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        let file = DocumentName.uniqueFileName(stem: derivedName.name, ext: TextDocument.pathExtension, existing: existing)
        return folderURL.appendingPathComponent(file)
    }

    // Writes a draft into its folder. Empty drafts are never written.
    func saveDraft(completion: @escaping (Bool) -> Void) {
        guard isUnwritten, !writingDraft else { completion(true); return }
        guard !currentText.isEmpty, let url = draftURL() else { completion(true); return }
        writingDraft = true
        save(to: url, ofType: fileType ?? "public.plain-text", for: .saveOperation) { error in
            self.writingDraft = false
            completion(error == nil)
        }
    }
    private var writingDraft = false

    override func save(withDelegate delegate: Any?, didSave didSaveSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard isUnwritten else {
            super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
            return
        }
        saveDraft { ok in
            Self.callBack(delegate, didSaveSelector, self, ok, contextInfo)
        }
    }

    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        guard isUnwritten else {
            super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
            return
        }
        // Periodic autosave waits for a final name; close/quit-time autosave writes whatever is there.
        if autosavingIsImplicitlyCancellable && !derivedName.isFinal { completionHandler(nil); return }
        saveDraft { _ in completionHandler(nil) }
    }

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard isUnwritten else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        saveDraft { ok in
            if !ok { self.updateChangeCount(.changeCleared) }
            Self.callBack(delegate, shouldCloseSelector, self, true, contextInfo)
        }
    }

    // `document:didSave:contextInfo:` / `document:shouldClose:contextInfo:`
    private static func callBack(_ delegate: Any?, _ selector: Selector?, _ document: NSDocument, _ flag: Bool, _ context: UnsafeMutableRawPointer?) {
        guard let target = delegate as? NSObject, let selector, let imp = target.method(for: selector) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(imp, to: Fn.self)(target, selector, document, flag, context)
    }

    // MARK: - External changes

    override func presentedItemDidChange() {
        DispatchQueue.main.async { self.externalChange() }
    }

    private func externalChange() {
        guard let url = fileURL,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              date != fileModificationDate else { return }
        if let disk = try? Data(contentsOf: url), let mine = try? data(ofType: fileType ?? ""), disk == mine {
            fileModificationDate = date
            return
        }
        if !isDocumentEdited {
            try? revert(toContentsOf: url, ofType: fileType ?? "public.plain-text")
            return
        }
        let alert = NSAlert()
        alert.messageText = String(format: L("The file “%@” was changed externally."), url.lastPathComponent)
        alert.addButton(withTitle: L("Keep Draft Version"))
        alert.addButton(withTitle: L("Revert"))
        alert.addButton(withTitle: L("Save As…"))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                self.fileModificationDate = date  // the disk version is being replaced on purpose
                self.save(nil)
            case .alertSecondButtonReturn: _ = try? self.revert(toContentsOf: url, ofType: self.fileType ?? "public.plain-text")
            default: self.saveAs(nil)
            }
        }
        if let window = library?.window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        let keep = library?.textView.selectedRange()
        try super.revert(toContentsOf: url, ofType: typeName)
        if let keep { selectedRange = NSRange(location: min(keep.location, (text as NSString).length), length: 0) }
        library?.reload(self)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
