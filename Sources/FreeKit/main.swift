import AppKit
import FreeKitCore

let arguments = CommandLine.arguments

if arguments.contains("--transcribe-file") {
    exit(TranscribeFileCommand.run(arguments: arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Full Dock presence: FreeKit acts like a normal app (Dock icon opens the
// control center via applicationShouldHandleReopen). Dictation still never
// steals focus — recording never activates the app.
app.setActivationPolicy(.regular)
app.mainMenu = buildMainMenu()
app.run()

// A programmatic app gets no main menu for free, and without an Edit menu the
// standard Cmd+C/V/X/Z shortcuts do not reach text views.
func buildMainMenu() -> NSMenu {
    let main = NSMenu()

    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About FreeKit",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide FreeKit",
                    action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit FreeKit",
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let appItem = NSMenuItem()
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
    let redo = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
    editMenu.addItem(redo)
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
    let editItem = NSMenuItem()
    editItem.submenu = editMenu
    main.addItem(editItem)

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                       keyEquivalent: "w")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                       keyEquivalent: "m")
    let windowItem = NSMenuItem()
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApplication.shared.windowsMenu = windowMenu

    return main
}
