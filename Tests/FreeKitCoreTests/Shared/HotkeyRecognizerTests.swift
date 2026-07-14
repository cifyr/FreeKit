import XCTest
@testable import FreeKitCore

final class HotkeyRecognizerTests: XCTestCase {
    private let optionFlag = HotkeyModifiers.option.rawValue
    private let commandFlag = HotkeyModifiers.command.rawValue

    // MARK: - Bare modifier presets

    func testModifierDownUpFires() {
        let recognizer = HotkeyRecognizer(preset: .rightOption)  // keyCode 61
        XCTAssertEqual(
            recognizer.handle(kind: .flagsChanged, keyCode: 61, flags: optionFlag, isAutorepeat: false),
            .fire(.down, swallow: false))
        XCTAssertEqual(
            recognizer.handle(kind: .flagsChanged, keyCode: 61, flags: 0, isAutorepeat: false),
            .fire(.up, swallow: false))
    }

    func testModifierDuplicateFlagEventsAreDebounced() {
        let recognizer = HotkeyRecognizer(preset: .rightOption)
        _ = recognizer.handle(kind: .flagsChanged, keyCode: 61, flags: optionFlag, isAutorepeat: false)
        XCTAssertEqual(
            recognizer.handle(kind: .flagsChanged, keyCode: 61, flags: optionFlag, isAutorepeat: false),
            .pass)
    }

    func testOtherModifierKeyCodePasses() {
        let recognizer = HotkeyRecognizer(preset: .rightOption)
        XCTAssertEqual(
            recognizer.handle(kind: .flagsChanged, keyCode: 54, flags: commandFlag, isAutorepeat: false),
            .pass)
    }

    // MARK: - Key and combo presets

    func testPlainKeyDownUpFiresAndSwallows() {
        let recognizer = HotkeyRecognizer(preset: .f13)  // keyCode 105
        XCTAssertEqual(
            recognizer.handle(kind: .keyDown, keyCode: 105, flags: 0, isAutorepeat: false),
            .fire(.down, swallow: true))
        XCTAssertEqual(
            recognizer.handle(kind: .keyUp, keyCode: 105, flags: 0, isAutorepeat: false),
            .fire(.up, swallow: true))
    }

    func testDisabledPresetNeverFires() {
        let recognizer = HotkeyRecognizer(preset: .disabled)
        XCTAssertEqual(
            recognizer.handle(kind: .keyDown, keyCode: 105, flags: 0, isAutorepeat: false),
            .pass)
        XCTAssertEqual(
            recognizer.handle(kind: .flagsChanged, keyCode: 61, flags: optionFlag, isAutorepeat: false),
            .pass)
    }

    func testAutorepeatWhileHeldIsSwallowedSilently() {
        let recognizer = HotkeyRecognizer(preset: .f13)
        _ = recognizer.handle(kind: .keyDown, keyCode: 105, flags: 0, isAutorepeat: false)
        XCTAssertEqual(
            recognizer.handle(kind: .keyDown, keyCode: 105, flags: 0, isAutorepeat: true),
            .swallow)
    }

    func testComboRequiresExactModifiers() {
        let preset = HotkeyPreset.custom(keyCode: 40, modifiers: [.command])  // Cmd+K
        let recognizer = HotkeyRecognizer(preset: preset)
        // Bare K without Cmd passes through untouched.
        XCTAssertEqual(
            recognizer.handle(kind: .keyDown, keyCode: 40, flags: 0, isAutorepeat: false),
            .pass)
        // Cmd+Opt+K is not Cmd+K.
        XCTAssertEqual(
            recognizer.handle(
                kind: .keyDown, keyCode: 40, flags: commandFlag | optionFlag, isAutorepeat: false),
            .pass)
        XCTAssertEqual(
            recognizer.handle(kind: .keyDown, keyCode: 40, flags: commandFlag, isAutorepeat: false),
            .fire(.down, swallow: true))
    }

    // Releasing Cmd before K must still end the combo, and K's trailing key-up
    // must be muted so the frontmost app never sees a stray K.
    func testModifierReleasedBeforeKeyMutesTrailingKeyUp() {
        let preset = HotkeyPreset.custom(keyCode: 40, modifiers: [.command])
        let recognizer = HotkeyRecognizer(preset: preset)
        _ = recognizer.handle(kind: .keyDown, keyCode: 40, flags: commandFlag, isAutorepeat: false)
        XCTAssertEqual(
            recognizer.handle(kind: .flagsChanged, keyCode: 55, flags: 0, isAutorepeat: false),
            .fire(.up, swallow: false))
        // Autorepeats of the still-held key stay swallowed.
        XCTAssertEqual(
            recognizer.handle(kind: .keyDown, keyCode: 40, flags: 0, isAutorepeat: true),
            .swallow)
        // The trailing key-up is consumed once, then the key behaves normally.
        XCTAssertEqual(
            recognizer.handle(kind: .keyUp, keyCode: 40, flags: 0, isAutorepeat: false),
            .swallow)
        XCTAssertEqual(
            recognizer.handle(kind: .keyUp, keyCode: 40, flags: 0, isAutorepeat: false),
            .pass)
    }

    func testResetClearsHeldState() {
        let recognizer = HotkeyRecognizer(preset: .f13)
        _ = recognizer.handle(kind: .keyDown, keyCode: 105, flags: 0, isAutorepeat: false)
        recognizer.reset(preset: .f13)
        // No stale comboIsDown: the next down fires again instead of swallowing.
        XCTAssertEqual(
            recognizer.handle(kind: .keyDown, keyCode: 105, flags: 0, isAutorepeat: false),
            .fire(.down, swallow: true))
    }
}
