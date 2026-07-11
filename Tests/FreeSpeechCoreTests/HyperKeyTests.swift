import XCTest
@testable import FreeSpeechCore

final class HyperKeyTests: XCTestCase {
    func testTriggerEventsAreAlwaysSwallowed() {
        let mapper = HyperKeyMapper(behavior: .hyper)
        XCTAssertEqual(mapper.handleTriggerDown(at: 0), .swallow)
        XCTAssertEqual(mapper.handleTriggerUp(at: 0.1), .swallow)
    }

    func testHyperAddsAllFourModifiersWhileHeld() {
        let mapper = HyperKeyMapper(behavior: .hyper)
        _ = mapper.handleTriggerDown(at: 0)
        XCTAssertEqual(
            mapper.handleOtherKey(flags: 0),
            .rewriteFlags(HyperKeyMapper.hyperFlags))
        _ = mapper.handleTriggerUp(at: 0.5)
        XCTAssertEqual(mapper.handleOtherKey(flags: 0), .pass)
    }

    func testExistingFlagsArePreserved() {
        let mapper = HyperKeyMapper(behavior: .command)
        _ = mapper.handleTriggerDown(at: 0)
        let shift = HotkeyModifiers.shift.rawValue
        XCTAssertEqual(
            mapper.handleOtherKey(flags: shift),
            .rewriteFlags(shift | HotkeyModifiers.command.rawValue))
    }

    func testEscapeFiresOnQuickLoneTap() {
        let mapper = HyperKeyMapper(behavior: .escapeTapHyperHold)
        _ = mapper.handleTriggerDown(at: 10)
        XCTAssertEqual(mapper.handleTriggerUp(at: 10.2), .swallowAndEmitEscape)
    }

    func testNoEscapeAfterChord() {
        let mapper = HyperKeyMapper(behavior: .escapeTapHyperHold)
        _ = mapper.handleTriggerDown(at: 10)
        XCTAssertEqual(
            mapper.handleOtherKey(flags: 0),
            .rewriteFlags(HyperKeyMapper.hyperFlags))
        XCTAssertEqual(mapper.handleTriggerUp(at: 10.2), .swallow)
    }

    func testNoEscapeOnSlowRelease() {
        let mapper = HyperKeyMapper(behavior: .escapeTapHyperHold)
        _ = mapper.handleTriggerDown(at: 10)
        XCTAssertEqual(mapper.handleTriggerUp(at: 10 + HyperKeyMapper.tapTimeout + 0.1), .swallow)
    }

    // The held trigger autorepeats as keyDown events; they must not restart the
    // tap timer or a long hold would still read as a tap.
    func testTriggerAutorepeatDoesNotResetTapTimer() {
        let mapper = HyperKeyMapper(behavior: .escapeTapHyperHold)
        _ = mapper.handleTriggerDown(at: 10)
        _ = mapper.handleTriggerDown(at: 10.9)
        XCTAssertEqual(mapper.handleTriggerUp(at: 11), .swallow)
    }

    func testResetChangesBehaviorAndClearsState() {
        let mapper = HyperKeyMapper(behavior: .hyper)
        _ = mapper.handleTriggerDown(at: 0)
        mapper.reset(behavior: .command)
        XCTAssertFalse(mapper.triggerIsDown)
        XCTAssertEqual(mapper.handleOtherKey(flags: 0), .pass)
        _ = mapper.handleTriggerDown(at: 1)
        XCTAssertEqual(
            mapper.handleOtherKey(flags: 0),
            .rewriteFlags(HotkeyModifiers.command.rawValue))
    }
}
