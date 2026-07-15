import Foundation

public enum ModuleStatus: String, Equatable {
    case available
    case comingSoon
}

// Pure metadata for one suite tool; the app-side AppModule owns the lifecycle.
public struct ModuleInfo: Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let symbolName: String
    public let status: ModuleStatus
    public let ownsMenuBarItem: Bool

    public init(id: String, displayName: String, summary: String, symbolName: String,
                status: ModuleStatus, ownsMenuBarItem: Bool) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.symbolName = symbolName
        self.status = status
        self.ownsMenuBarItem = ownsMenuBarItem
    }
}

// Single source of truth for every tool in the suite, in control-center display
// order: built tools first, coming-soon ones after.
public enum ModuleCatalog {
    public static let speech = ModuleInfo(
        id: "speech", displayName: "Speech",
        summary: "On-device dictation: hold a hotkey, speak, text lands at the caret.",
        symbolName: "mic", status: .available, ownsMenuBarItem: true)

    public static let notebook = ModuleInfo(
        id: "notebook", displayName: "Notebook",
        summary: "Floating scratch notes on a global hotkey. Searchable, styled, saved to disk.",
        symbolName: "note.text", status: .available, ownsMenuBarItem: true)

    // App-style tools (see `apps`) manage their own status item: it appears
    // only while the tool is open, so ownsMenuBarItem stays false and the
    // registry never forces it visible.
    public static let autoclicker = ModuleInfo(
        id: "autoclicker", displayName: "Tap",
        summary: "Autoclicker: fixed-interval clicks at the cursor or a set point.",
        symbolName: "cursorarrow.click.2", status: .available, ownsMenuBarItem: false)

    public static let stats = ModuleInfo(
        id: "stats", displayName: "Stats",
        summary: "Live CPU, memory, GPU, disk, network, and battery in the menu bar, with per-metric styles and colors.",
        symbolName: "gauge.with.dots.needle.50percent", status: .available, ownsMenuBarItem: true)

    // Display name is HyperKey; the persisted id stays "capslock" so existing
    // installs keep their saved enabled/hotkey state across the rename.
    public static let hyperKey = ModuleInfo(
        id: "capslock", displayName: "HyperKey",
        summary: "Remap the Caps Lock key to a hyper key, Command, or tap-for-Escape.",
        symbolName: "capslock", status: .available, ownsMenuBarItem: false)

    // Menu-bar manager in the spirit of the Ice app: hide/show other apps'
    // menu bar icons, plus a live view of every FreeKit tool's own icon.
    // Roadmap for now: the first pass's per-pid Cmd-drag technique doesn't
    // safely handle Control Center's grouped system items (battery, Wi-Fi,
    // Bluetooth all share one process — hiding one would drag all of them,
    // including Control Center's own icon), and needs a rework before it
    // ships as more than a catalog entry.
    public static let ice = ModuleInfo(
        id: "ice", displayName: "Ice",
        summary: "Menu bar manager: hide and show other apps' menu bar icons, and FreeKit's own.",
        symbolName: "snowflake", status: .comingSoon, ownsMenuBarItem: true)

    public static let cotypist = ModuleInfo(
        id: "cotypist", displayName: "Cotypist",
        summary: "On-device inline text prediction anywhere you type.",
        symbolName: "text.cursor", status: .comingSoon, ownsMenuBarItem: true)

    public static let appCleaner = ModuleInfo(
        id: "appcleaner", displayName: "AppCleaner",
        summary: "Uninstall apps together with their leftover support files.",
        symbolName: "trash", status: .available, ownsMenuBarItem: false)

    public static let linearMouse = ModuleInfo(
        id: "linearmouse", displayName: "LinearMouse",
        summary: "Per-device pointer acceleration and scroll direction control.",
        symbolName: "computermouse", status: .comingSoon, ownsMenuBarItem: true)

    public static let amphetamine = ModuleInfo(
        id: "amphetamine", displayName: "Amphetamine",
        summary: "Keep the Mac awake: timer tiers from the menu bar, or right-click to stay awake until you say stop.",
        symbolName: "pills", status: .available, ownsMenuBarItem: true)

    // id stays "clop" (persisted keys are namespaced by id) though the tool now
    // presents as "Simplify" — same trick as capslock/HyperKey above.
    public static let clop = ModuleInfo(
        id: "clop", displayName: "Simplify",
        summary: "Automatic image, video, and PDF compression on copy.",
        symbolName: "rectangle.compress.vertical", status: .available, ownsMenuBarItem: true)

    // Local, client-side format conversion (images/video/audio/docs), the
    // CloudConvert/FreeConvert niche without the upload. Prior art: p2r3/convert.
    // ownsMenuBarItem is true so the registry drives its persistent menu bar item
    // and its Tools-tab card gets the MENU show/hide checkbox — even though it is
    // also cross-listed in the Apps tab (see ModuleCatalog.apps).
    public static let convert = ModuleInfo(
        id: "convert", displayName: "Convert",
        summary: "Drag-and-drop file conversion between image, audio, video, and document formats, done on-device.",
        symbolName: "arrow.triangle.2.circlepath", status: .available, ownsMenuBarItem: true)

    // The shake gesture is the primary way in, but the icon is a handy way to
    // reopen a shelf that still has items parked on it, or to clear it.
    public static let shelf = ModuleInfo(
        id: "shelf", displayName: "Shelf",
        summary: "Wiggle a drag to park files on a floating shelf, then drop them anywhere.",
        symbolName: "tray.and.arrow.down", status: .available, ownsMenuBarItem: true)

    // Notch widget lives in the notch, so it never gets a menu bar item.
    public static let boringNotch = ModuleInfo(
        id: "boringnotch", displayName: "Notch",
        summary: "Spotify and Apple Music controls beside the notch, with your next calendar event.",
        symbolName: "sparkles.rectangle.stack", status: .available, ownsMenuBarItem: false)

    public static let all: [ModuleInfo] = [
        speech, notebook, autoclicker, stats, hyperKey, ice,
        cotypist, appCleaner, linearMouse, amphetamine, clop, shelf, boringNotch, convert,
    ]

    // Tools that read as small apps rather than ambient utilities; the control
    // center fronts these in the Apps tab with a one-click Open. Convert keeps
    // its Enabled/menu-bar toggles (which the Apps tab card doesn't show) in
    // its own settings pane instead of the card, since — unlike AppCleaner and
    // Tap — it has real background behavior tied to them (Finder services,
    // hotkeys, its persistent menu bar icon).
    public static let apps: [ModuleInfo] = [appCleaner, autoclicker, convert]

    public static func find(id: String) -> ModuleInfo? {
        all.first { $0.id == id }
    }
}

// Per-module persistence, namespaced so module keys can never collide with the
// Speech settings that predate the suite.
extension Settings {
    private func moduleKey(_ id: String, _ suffix: String) -> String {
        "module.\(id).\(suffix)"
    }

    // Every module starts disabled — the suite onboarding walks the user through
    // turning tools on one at a time, so nothing (Speech included) claims the menu
    // bar or a hotkey until it's been opted into.
    public func moduleEnabled(id: String) -> Bool {
        (defaultsValue(forKey: moduleKey(id, "enabled")) as? Bool) ?? false
    }

    public func setModuleEnabled(_ enabled: Bool, id: String) {
        setDefaultsValue(enabled, forKey: moduleKey(id, "enabled"))
    }

    public func moduleShowsMenuBarItem(id: String) -> Bool {
        (defaultsValue(forKey: moduleKey(id, "menuBarItem")) as? Bool) ?? true
    }

    public func setModuleShowsMenuBarItem(_ shows: Bool, id: String) {
        setDefaultsValue(shows, forKey: moduleKey(id, "menuBarItem"))
    }

    // Generic per-module global hotkey, stored the same way as the Speech hotkeys.
    public func moduleHotkey(id: String, defaultPreset: HotkeyPreset) -> HotkeyPreset {
        guard defaultsValue(forKey: moduleKey(id, "hotkeyKeyCode")) != nil else {
            return defaultPreset
        }
        let keyCode = (defaultsValue(forKey: moduleKey(id, "hotkeyKeyCode")) as? Int).map(Int64.init) ?? 0
        if keyCode == HotkeyPreset.disabled.keyCode { return .disabled }
        let modifiers = HotkeyModifiers(
            rawValue: UInt64((defaultsValue(forKey: moduleKey(id, "hotkeyModifiers")) as? Int) ?? 0))
        return .custom(keyCode: keyCode, modifiers: modifiers)
    }

    public func setModuleHotkey(_ preset: HotkeyPreset, id: String) {
        setDefaultsValue(Int(preset.keyCode), forKey: moduleKey(id, "hotkeyKeyCode"))
        setDefaultsValue(Int(preset.modifiers.rawValue), forKey: moduleKey(id, "hotkeyModifiers"))
    }

    public func moduleString(id: String, key: String) -> String? {
        defaultsValue(forKey: moduleKey(id, key)) as? String
    }

    public func setModuleString(_ value: String?, id: String, key: String) {
        setDefaultsValue(value, forKey: moduleKey(id, key))
    }

    public func moduleDouble(id: String, key: String) -> Double? {
        defaultsValue(forKey: moduleKey(id, key)) as? Double
    }

    public func setModuleDouble(_ value: Double?, id: String, key: String) {
        setDefaultsValue(value, forKey: moduleKey(id, key))
    }

    public func moduleInt(id: String, key: String) -> Int? {
        defaultsValue(forKey: moduleKey(id, key)) as? Int
    }

    public func setModuleInt(_ value: Int?, id: String, key: String) {
        setDefaultsValue(value, forKey: moduleKey(id, key))
    }

    public func moduleBool(id: String, key: String) -> Bool? {
        defaultsValue(forKey: moduleKey(id, key)) as? Bool
    }

    public func setModuleBool(_ value: Bool?, id: String, key: String) {
        setDefaultsValue(value, forKey: moduleKey(id, key))
    }
}
