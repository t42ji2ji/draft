import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("About Draft"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide Draft"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("Quit Draft"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: L("Draft"), to: main)

        let file = NSMenu(title: L("File"))
        file.addItem(withTitle: L("New"), action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: L("Open…"), action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        // ⌘W closes the document and leaves the library window up with a new draft (iA).
        file.addItem(withTitle: L("Close"), action: #selector(LibraryWindowController.closeDocument(_:)), keyEquivalent: "w")
        file.addItem(withTitle: L("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        file.addItem(withTitle: L("Save"), action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        // ⇧⌘S belongs to Strikethrough (Notion); autosaving apps put Save As on ⌥⇧⌘S.
        file.addItem(withTitle: L("Save As…"), action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S").keyEquivalentModifierMask = [.command, .shift, .option]
        file.addItem(.separator())
        file.addItem(withTitle: L("Export…"), action: #selector(LibraryWindowController.exportDocument(_:)), keyEquivalent: "E")
        file.addItem(withTitle: L("Print…"), action: #selector(LibraryWindowController.printPreview(_:)), keyEquivalent: "p")
        add(file, title: L("File"), to: main)

        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Copy HTML"), action: #selector(LibraryWindowController.copyHTML(_:)), keyEquivalent: "C")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Find…"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        add(edit, title: L("Edit"), to: main)

        // Format: Notion's shortcuts, writing Markdown.
        let format = NSMenu(title: L("Format"))
        for (title, action, key, mods) in [
            ("Bold", #selector(LibraryWindowController.formatBold(_:)), "b", NSEvent.ModifierFlags.command),
            ("Italic", #selector(LibraryWindowController.formatItalic(_:)), "i", .command),
            ("Strikethrough", #selector(LibraryWindowController.formatStrikethrough(_:)), "s", [.command, .shift]),
            ("Inline Code", #selector(LibraryWindowController.formatInlineCode(_:)), "e", .command),
            ("Highlight", #selector(LibraryWindowController.formatHighlight(_:)), "h", [.command, .shift]),
            ("Link", #selector(LibraryWindowController.formatLink(_:)), "k", .command),
        ] as [(String, Selector, String, NSEvent.ModifierFlags)] {
            format.addItem(withTitle: L(title), action: action, keyEquivalent: key).keyEquivalentModifierMask = mods
        }
        format.addItem(.separator())
        for (title, tag) in [("Body", 0), ("Heading 1", 1), ("Heading 2", 2), ("Heading 3", 3), ("To-do", 4), ("Bulleted List", 5), ("Numbered List", 6)] {
            let item = format.addItem(withTitle: L(title), action: #selector(LibraryWindowController.formatBlock(_:)), keyEquivalent: "\(tag)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = tag
        }
        format.addItem(withTitle: L("Code Block"), action: #selector(LibraryWindowController.formatCodeBlock(_:)), keyEquivalent: "8").keyEquivalentModifierMask = [.command, .option]
        add(format, title: L("Format"), to: main)

        let view = NSMenu(title: L("View"))
        view.addItem(withTitle: L("Bigger"), action: #selector(AppDelegate.biggerText(_:)), keyEquivalent: "+")
        view.addItem(withTitle: L("Smaller"), action: #selector(AppDelegate.smallerText(_:)), keyEquivalent: "-")
        view.addItem(withTitle: L("Actual Size"), action: #selector(AppDelegate.actualSizeText(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        view.addItem(withTitle: L("Show Library"), action: #selector(LibraryWindowController.toggleLibrary(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        view.addItem(withTitle: L("Show Outline"), action: #selector(LibraryWindowController.toggleOutline(_:)), keyEquivalent: "O")
        view.addItem(withTitle: L("Show Preview"), action: #selector(LibraryWindowController.togglePreview(_:)), keyEquivalent: "r")
        view.addItem(withTitle: L("Show Assistant"), action: #selector(LibraryWindowController.toggleAssistant(_:)), keyEquivalent: "j")
        view.addItem(withTitle: L("Reload Preview"), action: #selector(LibraryWindowController.reloadPreview(_:)), keyEquivalent: "R")
        for (title, tag) in [("Full", 0), ("Split", 1)] {
            view.addItem(withTitle: L(title), action: #selector(LibraryWindowController.changePreviewWidthTo(_:)), keyEquivalent: "").tag = tag
        }
        for (title, tag) in [("Web", 0), ("PDF", 1)] {
            view.addItem(withTitle: L(title), action: #selector(LibraryWindowController.changePreviewDisplayModeTo(_:)), keyEquivalent: "").tag = tag
        }
        view.addItem(.separator())
        for (title, action, options) in [("Title Bar", #selector(LibraryWindowController.changeTitlebarVisibility(_:)), ["Fade In/Out", "Always Show"]),
                                         ("Toolbar", #selector(LibraryWindowController.changeToolbarVisibility(_:)), ["Fade In/Out", "Always Show", "Hide"])] {
            let menu = NSMenu(title: title)
            for (tag, option) in options.enumerated() { menu.addItem(withTitle: L(option), action: action, keyEquivalent: "").tag = tag }
            view.addItem(withTitle: L(title), action: nil, keyEquivalent: "").submenu = menu
        }
        view.addItem(.separator())
        view.addItem(withTitle: L("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        add(view, title: L("View"), to: main)

        // Same layout and shortcuts as iA Writer's Focus menu.
        let focus = NSMenu(title: L("Focus"))
        focus.addItem(withTitle: L("Enable Focus Mode"), action: #selector(EditorTextView.toggleFocusMode(_:)), keyEquivalent: "d")
        for (title, scope) in [("Sentence", EditorTextView.FocusScope.sentence), ("Paragraph", .paragraph), ("Typewriter", .typewriter)] {
            focus.addItem(withTitle: L(title), action: #selector(EditorTextView.selectFocusScope(_:)), keyEquivalent: "").tag = scope.rawValue
        }
        // Draft addition: where the caret line sits while focus mode is on.
        let position = NSMenu(title: L("Caret Line"))
        for (title, value) in [("Centered", EditorTextView.TypewriterPosition.center), ("Upper Third", .upper), ("Free Scrolling", .off)] {
            position.addItem(withTitle: L(title), action: #selector(EditorTextView.selectTypewriterPosition(_:)), keyEquivalent: "").tag = value.rawValue
        }
        focus.addItem(withTitle: L("Caret Line"), action: nil, keyEquivalent: "").submenu = position
        focus.addItem(.separator())
        focus.addItem(withTitle: L("Show Syntax"), action: #selector(EditorTextView.toggleSyntaxControl(_:)), keyEquivalent: "D")
        for (title, pos) in [("Adjectives", PartOfSpeech.adjective), ("Nouns", .noun), ("Adverbs", .adverb), ("Verbs", .verb), ("Conjunctions", .conjunction)] {
            let item = focus.addItem(withTitle: L(title), action: #selector(EditorTextView.toggleSyntaxTarget(_:)), keyEquivalent: "")
            item.tag = pos.rawValue
            item.indentationLevel = 1
        }
        focus.addItem(.separator())
        focus.addItem(withTitle: L("Enable Style Check"), action: #selector(EditorTextView.toggleStyleCheck(_:)), keyEquivalent: "D").keyEquivalentModifierMask = [.command, .option]
        for (title, category) in [("Fillers", StyleCategory.fillers), ("Clichés", .cliches), ("Redundancies", .redundancies)] {
            let item = focus.addItem(withTitle: L(title), action: #selector(EditorTextView.toggleStyleTarget(_:)), keyEquivalent: "")
            item.tag = category.rawValue
            item.indentationLevel = 1
        }
        add(focus, title: L("Focus"), to: main)

        let window = NSMenu(title: L("Window"))
        window.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        add(window, title: L("Window"), to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
