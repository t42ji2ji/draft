import AppKit

// The Library menu, placed before Window. Actions go to the library window controller through the responder chain.
enum LibraryMenu {
    static func install(in main: NSMenu) {
        let menu = NSMenu(title: L("Library"))
        menu.addItem(withTitle: L("Rename…"), action: #selector(LibraryWindowController.renameCurrentDocument(_:)), keyEquivalent: "")
        let item = NSMenuItem(title: L("Library"), action: nil, keyEquivalent: "")
        item.submenu = menu
        let window = main.items.firstIndex { $0.submenu === NSApp.windowsMenu } ?? main.items.count
        main.insertItem(item, at: window)
    }
}
