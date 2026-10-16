import AppKit

// ⌘N creates a draft in the browsed folder; up to 10 documents stay loaded without a window (docs/storage.md §4).
final class DocumentController: NSDocumentController {
    static let maximumInactiveDocuments = 10

    override var defaultType: String? { "public.plain-text" }

    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        let document = try super.makeUntitledDocument(ofType: typeName)
        (document as? TextDocument)?.folderURL = LibraryWindowController.existing?.newDocumentFolder ?? Library.rootURL
        return document
    }

    override func newDocument(_ sender: Any?) {
        // Reuse an empty never-saved draft already on screen (iA's _reuseOpenDocumentForNewWithFolderURL:).
        if let library = LibraryWindowController.existing, let current = library.document as? TextDocument,
           current.isUnwritten, current.currentText.isEmpty {
            current.folderURL = library.newDocumentFolder
            library.showWindow(nil)
            return
        }
        super.newDocument(sender)
    }

    // True while AppKit closes every document (quit); the library window then leaves its documents to AppKit.
    private(set) var closingAll = false

    override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool, delegate: Any?, didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        closingAll = true
        super.reviewUnsavedDocuments(withAlertTitle: title, cancellable: cancellable, delegate: delegate, didReviewAllSelector: didReviewAllSelector, contextInfo: contextInfo)
    }

    override func closeAllDocuments(withDelegate delegate: Any?, didCloseAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        closingAll = true
        super.closeAllDocuments(withDelegate: delegate, didCloseAllSelector: didCloseAllSelector, contextInfo: contextInfo)
    }

    // Close the oldest documents that are loaded but not shown.
    func trimInactiveDocuments() {
        let inactive = documents.compactMap { $0 as? TextDocument }
            .filter { $0.windowControllers.isEmpty }
            .sorted { $0.lastShown > $1.lastShown }
        for document in inactive.dropFirst(Self.maximumInactiveDocuments) {
            close(document)
        }
    }

    func close(_ document: TextDocument) {
        if document.isUnwritten && document.text.isEmpty { document.close(); return }
        document.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if shouldClose { document.close() }
    }
}
