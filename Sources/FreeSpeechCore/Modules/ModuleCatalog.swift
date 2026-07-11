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

    public static let autoclicker = ModuleInfo(
        id: "autoclicker", displayName: "Tap",
        summary: "Autoclicker: fixed-interval clicks at the cursor or a set point.",
        symbolName: "cursorarrow.click.2", status: .available, ownsMenuBarItem: true)

    public static let stats = ModuleInfo(
        id: "stats", displayName: "Stats",
        summary: "Live CPU, memory, network throughput, and Bluetooth battery in the menu bar.",
        symbolName: "gauge.with.dots.needle.50percent", status: .available, ownsMenuBarItem: true)

    public static let capsLock = ModuleInfo(
        id: "capslock", displayName: "Caps Lock",
        summary: "Remap Caps Lock to a hyper key, Command, or tap-for-Escape.",
        symbolName: "capslock", status: .available, ownsMenuBarItem: false)

    public static let menuBarManager = ModuleInfo(
        id: "menubar", displayName: "Menu Bar",
        summary: "Hide and rearrange system-wide menu bar items, Ice-style.",
        symbolName: "menubar.rectangle", status: .comingSoon, ownsMenuBarItem: true)

    public static let cotypist = ModuleInfo(
        id: "cotypist", displayName: "Cotypist",
        summary: "On-device inline text prediction anywhere you type.",
        symbolName: "text.cursor", status: .comingSoon, ownsMenuBarItem: true)

    public static let appCleaner = ModuleInfo(
        id: "appcleaner", displayName: "AppCleaner",
        summary: "Uninstall apps together with their leftover support files.",
        symbolName: "trash", status: .available, ownsMenuBarItem: true)

    public static let linearMouse = ModuleInfo(
        id: "linearmouse", displayName: "LinearMouse",
        summary: "Per-device pointer acceleration and scroll direction control.",
        symbolName: "computermouse", status: .comingSoon, ownsMenuBarItem: true)

    public static let clop = ModuleInfo(
        id: "clop", displayName: "Clop",
        summary: "Automatic image, video, and PDF compression on copy.",
        symbolName: "rectangle.compress.vertical", status: .comingSoon, ownsMenuBarItem: true)

    // Notch widget lives in the notch, so it never gets a menu bar item.
    public static let boringNotch = ModuleInfo(
        id: "boringnotch", displayName: "Boring Notch",
        summary: "Turns the notch area into a small widget surface.",
        symbolName: "sparkles.rectangle.stack", status: .comingSoon, ownsMenuBarItem: false)

    public static let all: [ModuleInfo] = [
        speech, notebook, autoclicker, stats, capsLock,
        menuBarManager, cotypist, appCleaner, linearMouse, clop, boringNotch,
    ]

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

    // Only Speech starts enabled: it predates the suite, and defaulting new
    // tools off keeps the menu bar uncluttered until the user opts in.
    public func moduleEnabled(id: String) -> Bool {
        (defaultsValue(forKey: moduleKey(id, "enabled")) as? Bool) ?? (id == ModuleCatalog.speech.id)
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
