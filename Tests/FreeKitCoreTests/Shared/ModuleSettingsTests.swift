import XCTest
@testable import FreeKitCore

final class ModuleSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: Settings!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.cadenwarren.freespeech.module-tests")!
        defaults.removePersistentDomain(forName: "com.cadenwarren.freespeech.module-tests")
        settings = Settings(defaults: defaults)
    }

    func testCatalogHasNoDuplicateIDs() {
        let ids = ModuleCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testCatalogFindsByID() {
        XCTAssertEqual(ModuleCatalog.find(id: "speech"), ModuleCatalog.speech)
        XCTAssertNil(ModuleCatalog.find(id: "nope"))
    }

    func testBoringNotchNeverOwnsMenuBarItem() {
        XCTAssertFalse(ModuleCatalog.boringNotch.ownsMenuBarItem)
    }

    // The Apps tab renders these with a one-click Open, so every entry must be
    // a buildable catalog member, not a coming-soon placeholder. Apps manage
    // their own open-window-only status item, so the registry must never own it.
    func testAppsAreAvailableCatalogMembers() {
        XCTAssertFalse(ModuleCatalog.apps.isEmpty)
        for info in ModuleCatalog.apps {
            XCTAssertEqual(info.status, .available, "\(info.id) must be available")
            XCTAssertTrue(ModuleCatalog.all.contains(info), "\(info.id) missing from catalog")
            // App-style tools show their status item only while open, so the
            // registry must not drive it — except Convert, which is cross-listed
            // into Tools and keeps a persistent, MENU-toggleable item.
            if info.id != ModuleCatalog.convert.id {
                XCTAssertFalse(info.ownsMenuBarItem, "\(info.id) must self-manage its menu bar item")
            }
        }
    }

    // Speech predates the suite so it must stay on after the upgrade; new tools
    // start off to keep the menu bar quiet until the user opts in.
    func testOnlySpeechIsEnabledByDefault() {
        XCTAssertTrue(settings.moduleEnabled(id: ModuleCatalog.speech.id))
        for info in ModuleCatalog.all where info.id != ModuleCatalog.speech.id {
            XCTAssertFalse(settings.moduleEnabled(id: info.id), "\(info.id) should default off")
        }
    }

    func testEnabledRoundTrip() {
        settings.setModuleEnabled(true, id: "notebook")
        XCTAssertTrue(settings.moduleEnabled(id: "notebook"))
        settings.setModuleEnabled(false, id: "notebook")
        XCTAssertFalse(settings.moduleEnabled(id: "notebook"))
        // Speech can be turned off too — the default only applies when unset.
        settings.setModuleEnabled(false, id: "speech")
        XCTAssertFalse(settings.moduleEnabled(id: "speech"))
    }

    func testMenuBarItemDefaultsOnAndRoundTrips() {
        XCTAssertTrue(settings.moduleShowsMenuBarItem(id: "stats"))
        settings.setModuleShowsMenuBarItem(false, id: "stats")
        XCTAssertFalse(settings.moduleShowsMenuBarItem(id: "stats"))
    }

    // Every menu-bar-owning tool gets a MENU toggle in the control center: each
    // must start visible, survive a relaunch, and never drag the others with it.
    func testMenuBarItemTogglesAreIndependentPerModule() {
        let owners = ModuleCatalog.all.filter(\.ownsMenuBarItem)
        XCTAssertFalse(owners.isEmpty)
        for info in owners {
            XCTAssertTrue(settings.moduleShowsMenuBarItem(id: info.id),
                          "\(info.id) should default to a visible menu bar item")
        }

        settings.setModuleShowsMenuBarItem(false, id: ModuleCatalog.stats.id)

        let restored = Settings(defaults: defaults)
        XCTAssertFalse(restored.moduleShowsMenuBarItem(id: ModuleCatalog.stats.id))
        for info in owners where info.id != ModuleCatalog.stats.id {
            XCTAssertTrue(restored.moduleShowsMenuBarItem(id: info.id),
                          "hiding stats must not hide \(info.id)")
        }
    }

    // Hiding the item is independent of enabling the tool: a hidden Stats stays
    // enabled (its settings window still works), and re-showing needs no relaunch.
    func testMenuBarItemVisibilityIsIndependentOfEnabled() {
        settings.setModuleEnabled(true, id: ModuleCatalog.stats.id)
        settings.setModuleShowsMenuBarItem(false, id: ModuleCatalog.stats.id)

        XCTAssertTrue(settings.moduleEnabled(id: ModuleCatalog.stats.id))
        XCTAssertFalse(settings.moduleShowsMenuBarItem(id: ModuleCatalog.stats.id))

        settings.setModuleShowsMenuBarItem(true, id: ModuleCatalog.stats.id)
        XCTAssertTrue(settings.moduleShowsMenuBarItem(id: ModuleCatalog.stats.id))
    }

    func testModuleHotkeyFallsBackToDefaultThenPersists() {
        let fallback = HotkeyPreset.custom(keyCode: 45, modifiers: [.control, .option])
        XCTAssertEqual(
            settings.moduleHotkey(id: "notebook", defaultPreset: fallback).keyCode, 45)

        settings.setModuleHotkey(
            HotkeyPreset.custom(keyCode: 105, modifiers: []), id: "notebook")
        let restored = Settings(defaults: defaults)
            .moduleHotkey(id: "notebook", defaultPreset: fallback)
        XCTAssertEqual(restored.keyCode, 105)
        XCTAssertEqual(restored.modifiers, [])
    }

    func testModuleHotkeyCanBeDisabled() {
        settings.setModuleHotkey(.disabled, id: "notebook")
        XCTAssertEqual(
            Settings(defaults: defaults).moduleHotkey(
                id: "notebook", defaultPreset: .f13),
            .disabled)
    }

    func testModuleScalarsAreNamespacedPerModule() {
        settings.setModuleDouble(0.25, id: "autoclicker", key: "interval")
        settings.setModuleInt(100, id: "autoclicker", key: "maxClicks")
        settings.setModuleString("hyper", id: "capslock", key: "behavior")
        settings.setModuleBool(true, id: "notebook", key: "flag")

        XCTAssertEqual(settings.moduleDouble(id: "autoclicker", key: "interval"), 0.25)
        XCTAssertEqual(settings.moduleInt(id: "autoclicker", key: "maxClicks"), 100)
        XCTAssertEqual(settings.moduleString(id: "capslock", key: "behavior"), "hyper")
        XCTAssertEqual(settings.moduleBool(id: "notebook", key: "flag"), true)
        // Same key under another module id stays unset.
        XCTAssertNil(settings.moduleDouble(id: "notebook", key: "interval"))
    }
}
