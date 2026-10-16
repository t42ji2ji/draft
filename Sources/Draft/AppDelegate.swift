import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        // The first NSDocumentController created becomes the shared one.
        _ = DocumentController()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        installMenu()
        NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: .main) { _ in self.installMenu() }
        for name in ["iAWriterMono", "iAWriterMono-Italic", "iAWriterFullSpaceTC", "iAWriterDuo", "iAWriterDuo-Italic", "iAWriterQuattro", "iAWriterQuattro-Italic"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    // Built again when the language changes.
    private func installMenu() {
        NSApp.mainMenu = MainMenu.build()
        LibraryMenu.install(in: NSApp.mainMenu!)
    }

    // The window is up before the library is scanned; the list fills in when the scan lands.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit skips the untitled document when it restores state after a crash or kill; always start with a window.
        DispatchQueue.main.async {
            if LibraryWindowController.existing == nil, !self.openingLast, !self.openLastDocument() { NSDocumentController.shared.newDocument(nil) }
            Library.shared.start()
            LibrarySync.shared.start(libraryURL: Library.rootURL)  // no-op while SyncEnabled is off
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LibrarySync.shared.flush()
    }

    // Launch (or a Dock click with no window) picks up the file shown last, if it's still there.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { !openLastDocument() }

    // Set while that file is being read, so launch doesn't open it a second time.
    private var openingLast = false

    private func openLastDocument() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: LibraryWindowController.lastDocumentKey),
              FileManager.default.fileExists(atPath: path) else { return false }
        openingLast = true
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, error in
            self.openingLast = false
            if error != nil { NSDocumentController.shared.newDocument(nil) }
        }
        return true
    }
}
