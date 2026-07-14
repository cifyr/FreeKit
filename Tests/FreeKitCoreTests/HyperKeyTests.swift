import XCTest
@testable import FreeKitCore

final class HyperKeyTests: XCTestCase {
    func testTriggerEventsAreAlwaysSwallowed() {
        let mapper = HyperKeyMapper(config: .hyper)
        XCTAssertEqual(mapper.handleTriggerDown(at: 0), .swallow)
        XCTAssertEqual(mapper.handleTriggerUp(at: 0.1), .swallow)
    }

    func testHyperAddsAllFourModifiersWhileHeld() {
        let mapper = HyperKeyMapper(config: .hyper)
        _ = mapper.handleTriggerDown(at: 0)
        XCTAssertEqual(
            mapper.handleOtherKey(flags: 0),
            .rewriteFlags(HyperKeyMapper.hyperFlags))
        _ = mapper.handleTriggerUp(at: 0.5)
        XCTAssertEqual(mapper.handleOtherKey(flags: 0), .pass)
    }

    func testExistingFlagsArePreserved() {
        let mapper = HyperKeyMapper(config: .command)
        _ = mapper.handleTriggerDown(at: 0)
        let shift = HotkeyModifiers.shift.rawValue
        XCTAssertEqual(
            mapper.handleOtherKey(flags: shift),
            .rewriteFlags(shift | HotkeyModifiers.command.rawValue))
    }

    // Anything should be possible: an arbitrary user-composed modifier mix.
    func testCustomModifierCombination() {
        let combo = HotkeyModifiers([.option, .shift]).rawValue
        let mapper = HyperKeyMapper(config: .init(holdFlags: combo, tapEmitsEscape: false))
        _ = mapper.handleTriggerDown(at: 0)
        XCTAssertEqual(mapper.handleOtherKey(flags: 0), .rewriteFlags(combo))
    }

    func testEscapeFiresOnQuickLoneTap() {
        let mapper = HyperKeyMapper(config: .init(
            holdFlags: HyperKeyMapper.hyperFlags, tapEmitsEscape: true))
        _ = mapper.handleTriggerDown(at: 10)
        XCTAssertEqual(mapper.handleTriggerUp(at: 10.2), .swallowAndEmitEscape)
    }

    func testNoEscapeAfterChord() {
        let mapper = HyperKeyMapper(config: .init(
            holdFlags: HyperKeyMapper.hyperFlags, tapEmitsEscape: true))
        _ = mapper.handleTriggerDown(at: 10)
        XCTAssertEqual(
            mapper.handleOtherKey(flags: 0),
            .rewriteFlags(HyperKeyMapper.hyperFlags))
        XCTAssertEqual(mapper.handleTriggerUp(at: 10.2), .swallow)
    }

    func testNoEscapeOnSlowRelease() {
        let mapper = HyperKeyMapper(config: .init(
            holdFlags: HyperKeyMapper.hyperFlags, tapEmitsEscape: true))
        _ = mapper.handleTriggerDown(at: 10)
        XCTAssertEqual(mapper.handleTriggerUp(at: 10 + HyperKeyMapper.tapTimeout + 0.1), .swallow)
    }

    func testNoEscapeWhenDisabled() {
        let mapper = HyperKeyMapper(config: .hyper)
        _ = mapper.handleTriggerDown(at: 10)
        XCTAssertEqual(mapper.handleTriggerUp(at: 10.1), .swallow)
    }

    // The held trigger autorepeats as keyDown events; they must not restart the
    // tap timer or a long hold would still read as a tap.
    func testTriggerAutorepeatDoesNotResetTapTimer() {
        let mapper = HyperKeyMapper(config: .init(
            holdFlags: HyperKeyMapper.hyperFlags, tapEmitsEscape: true))
        _ = mapper.handleTriggerDown(at: 10)
        _ = mapper.handleTriggerDown(at: 10.9)
        XCTAssertEqual(mapper.handleTriggerUp(at: 11), .swallow)
    }

    func testResetChangesConfigAndClearsState() {
        let mapper = HyperKeyMapper(config: .hyper)
        _ = mapper.handleTriggerDown(at: 0)
        mapper.reset(config: .command)
        XCTAssertFalse(mapper.triggerIsDown)
        XCTAssertEqual(mapper.handleOtherKey(flags: 0), .pass)
        _ = mapper.handleTriggerDown(at: 1)
        XCTAssertEqual(
            mapper.handleOtherKey(flags: 0),
            .rewriteFlags(HotkeyModifiers.command.rawValue))
    }

    // The full hyper combo renders as the single hyper glyph in shortcut
    // displays; partial combos keep the per-modifier symbols.
    func testHyperComboCollapsesToGlyph() {
        XCTAssertEqual(HotkeyModifiers.hyper.symbols, "\u{2726}")
        XCTAssertEqual(
            HotkeyModifiers([.control, .option, .shift, .command, .fn]).symbols, "\u{2726}fn")
        XCTAssertEqual(HotkeyModifiers([.command, .shift]).symbols, "\u{21E7}\u{2318}")
        let preset = HotkeyPreset.custom(keyCode: 40, modifiers: .hyper)  // Hyper+K
        XCTAssertEqual(preset.displayName, "\u{2726} K")
    }
}
