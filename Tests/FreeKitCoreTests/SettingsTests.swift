import XCTest
@testable import FreeKitCore

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: Settings!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.cadenwarren.freespeech.tests")!
        defaults.removePersistentDomain(forName: "com.cadenwarren.freespeech.tests")
        settings = Settings(defaults: defaults)
    }

    func testDefaults() {
        XCTAssertEqual(settings.mode, .pushToTalk)
        XCTAssertEqual(settings.hotkey, .rightOption)
        XCTAssertEqual(settings.postProcessing, .cleanup)
        XCTAssertEqual(settings.tone, .professional)
        XCTAssertEqual(settings.maxRecordingSeconds, 60)
        XCTAssertFalse(settings.vocabularyHint.isEmpty)
    }

    func testCustomHotkeyRoundTrip() {
        settings.hotkey = HotkeyPreset.custom(keyCode: 96)  // F5
        let restored = Settings(defaults: defaults).hotkey
        XCTAssertEqual(restored.keyCode, 96)
        XCTAssertEqual(restored.kind, .key)
        XCTAssertEqual(restored.displayName, "F5")
    }

    func testCustomModifierHotkeyIsModifierKind() {
        settings.hotkey = HotkeyPreset.custom(keyCode: 54)  // Right Command
        let restored = Settings(defaults: defaults).hotkey
        XCTAssertEqual(restored.kind, .modifier)
        XCTAssertEqual(restored.displayName, "Right Command")
    }

    func testPresetHotkeyRoundTrip() {
        settings.hotkey = .f13
        XCTAssertEqual(Settings(defaults: defaults).hotkey, .f13)
    }

    func testDisabledHotkeysRoundTrip() {
        settings.hotkey = .disabled
        settings.systemAudioHotkey = .disabled
        let restored = Settings(defaults: defaults)
        XCTAssertEqual(restored.hotkey, .disabled)
        XCTAssertEqual(restored.systemAudioHotkey, .disabled)
        XCTAssertEqual(restored.hotkey.displayName, "Not Set")
    }

    func testPostProcessingRoundTrip() {
        settings.postProcessing = .tone
        settings.tone = .concise
        let restored = Settings(defaults: defaults)
        XCTAssertEqual(restored.postProcessing, .tone)
        XCTAssertEqual(restored.tone, .concise)
    }

    func testLanguageModelRequirement() {
        XCTAssertFalse(PostProcessingMode.off.needsLanguageModel)
        XCTAssertFalse(PostProcessingMode.cleanup.needsLanguageModel)
        XCTAssertTrue(PostProcessingMode.grammar.needsLanguageModel)
        XCTAssertTrue(PostProcessingMode.structure.needsLanguageModel)
        XCTAssertTrue(PostProcessingMode.tone.needsLanguageModel)
    }

    func testKeyNames() {
        XCTAssertEqual(KeyNames.name(forKeyCode: 61), "Right Option")
        XCTAssertEqual(KeyNames.name(forKeyCode: 9), "V")
        XCTAssertEqual(KeyNames.name(forKeyCode: 9999), "Key 9999")
        XCTAssertTrue(KeyNames.isModifier(61))
        XCTAssertFalse(KeyNames.isModifier(9))
    }
}
