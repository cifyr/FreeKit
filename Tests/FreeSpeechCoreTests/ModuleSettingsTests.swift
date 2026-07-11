import XCTest
@testable import FreeSpeechCore

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
