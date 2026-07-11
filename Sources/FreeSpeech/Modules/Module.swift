import AppKit
import SwiftUI
import FreeSpeechCore

// SwiftUI also exports a `Settings` scene; module files import both, so pin
// the bare name to ours once for the whole target.
typealias Settings = FreeSpeechCore.Settings

// Where a module's settings live: rich tools get their own window, tools with
// one or two simple controls stay inline in the control-center card.
enum ModuleSettingsStyle {
    case window
    case inline
    case none
}

// App-side lifecycle counterpart of ModuleInfo. Modules construct their runtime
// pieces lazily in activate() so a disabled tool costs nothing at launch.
protocol AppModule: AnyObject {
    var info: ModuleInfo { get }
    func activate()
    func deactivate()
    // Only called on ownsMenuBarItem modules, and only while active.
    func setMenuBarItemVisible(_ visible: Bool)
    var settingsStyle: ModuleSettingsStyle { get }
    // Settings content: hosted in the module's own window (.window) or inside
    // the control-center card (.inline).
    func makeSettingsPane() -> AnyView
    func openSettings()
}

extension AppModule {
    var settingsStyle: ModuleSettingsStyle { .window }
    func openSettings() {}
}

// Coming-soon tools: real catalog entry, greyed-out card, zero runtime behavior.
final class PlaceholderModule: AppModule {
    let info: ModuleInfo

    init(info: ModuleInfo) {
        self.info = info
    }

    func activate() {}
    func deactivate() {}
    func setMenuBarItemVisible(_ visible: Bool) {}
    var settingsStyle: ModuleSettingsStyle { .none }
    func makeSettingsPane() -> AnyView { AnyView(EmptyView()) }
}

// Owns every module, applies persisted enabled/menu-bar state, and performs
// live activate/deactivate so toggles never need a relaunch.
final class ModuleRegistry: ObservableObject {
    private let settings: Settings
    private(set) var modules: [AppModule] = []
    // Bumped on every state change so SwiftUI cards re-read Settings.
    @Published private(set) var revision = 0

    init(settings: Settings) {
        self.settings = settings
    }

    func register(_ module: AppModule) {
        modules.append(module)
    }

    func module(id: String) -> AppModule? {
        modules.first { $0.info.id == id }
    }

    func isEnabled(id: String) -> Bool {
        settings.moduleEnabled(id: id)
    }

    func showsMenuBarItem(id: String) -> Bool {
        settings.moduleShowsMenuBarItem(id: id)
    }

    func activateEnabledModules() {
        for module in modules
        where module.info.status == .available && settings.moduleEnabled(id: module.info.id) {
            Log.info("module \(module.info.id): activating at launch")
            module.activate()
            if module.info.ownsMenuBarItem {
                module.setMenuBarItemVisible(settings.moduleShowsMenuBarItem(id: module.info.id))
            }
        }
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let module = module(id: id), module.info.status == .available else { return }
        guard settings.moduleEnabled(id: id) != enabled else { return }
        settings.setModuleEnabled(enabled, id: id)
        Log.info("module \(id): \(enabled ? "enabled" : "disabled")")
        if enabled {
            module.activate()
            if module.info.ownsMenuBarItem {
                module.setMenuBarItemVisible(settings.moduleShowsMenuBarItem(id: id))
            }
        } else {
            if module.info.ownsMenuBarItem {
                module.setMenuBarItemVisible(false)
            }
            module.deactivate()
        }
        revision += 1
    }

    func setShowsMenuBarItem(_ shows: Bool, id: String) {
        guard let module = module(id: id), module.info.status == .available,
              module.info.ownsMenuBarItem else { return }
        guard settings.moduleShowsMenuBarItem(id: id) != shows else { return }
        settings.setModuleShowsMenuBarItem(shows, id: id)
        Log.info("module \(id): menu bar item \(shows ? "shown" : "hidden")")
        if settings.moduleEnabled(id: id) {
            module.setMenuBarItemVisible(shows)
        }
        revision += 1
    }
}
