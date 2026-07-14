import XCTest
@testable import FreeKitCore

final class MacroTests: XCTestCase {
    func testJSONRoundTrip() {
        let macro = Macro(
            steps: [
                .click(button: .left, type: .single, x: 100, y: 250),
                .key(keyCode: 36, modifiers: HotkeyModifiers.command.rawValue),
                .wait(seconds: 1.5),
                .click(button: .right, type: .double, x: nil, y: nil),
            ],
            repeatCount: 3, interval: 0.75, stepGap: 0.1)
        let json = macro.encodedJSON()
        XCTAssertNotNil(json)
        XCTAssertEqual(Macro.decode(json: json!), macro)
    }

    func testDecodeGarbageReturnsNil() {
        XCTAssertNil(Macro.decode(json: "not json"))
    }

    func testRepeatCompletion() {
        let bounded = Macro(steps: [.wait(seconds: 1)], repeatCount: 2)
        XCTAssertFalse(bounded.isComplete(afterRuns: 1))
        XCTAssertTrue(bounded.isComplete(afterRuns: 2))
        let unbounded = Macro(steps: [.wait(seconds: 1)], repeatCount: 0)
        XCTAssertFalse(unbounded.isComplete(afterRuns: 1_000_000))
    }

    func testNegativeTimingClampsToZero() {
        let macro = Macro(steps: [], repeatCount: -2, interval: -1, stepGap: -1)
        XCTAssertEqual(macro.repeatCount, 0)
        XCTAssertEqual(macro.interval, 0)
        XCTAssertEqual(macro.stepGap, 0)
    }

    func testMacroLibraryRoundTrip() {
        let library = [
            NamedMacro(name: "login", macro: Macro(
                steps: [.key(keyCode: 36, modifiers: 0)], repeatCount: 1)),
            NamedMacro(name: "farm", macro: Macro(
                steps: [.click(button: .left, type: .single, x: 5, y: 6)], repeatCount: 0)),
        ]
        let json = MacroLibrary.encode(library)
        XCTAssertNotNil(json)
        XCTAssertEqual(MacroLibrary.decode(json: json), library)
        XCTAssertEqual(MacroLibrary.decode(json: nil), [])
        XCTAssertEqual(MacroLibrary.decode(json: "garbage"), [])
    }

    func testStepSummaries() {
        XCTAssertEqual(
            MacroStep.click(button: .left, type: .single, x: 10, y: 20).summary,
            "Click at (10, 20)")
        XCTAssertEqual(
            MacroStep.click(button: .right, type: .double, x: nil, y: nil).summary,
            "Double-click (right) at cursor")
        XCTAssertEqual(
            MacroStep.key(keyCode: 40, modifiers: HotkeyModifiers.command.rawValue).summary,
            "Press \u{2318} K")
        XCTAssertEqual(
            MacroStep.key(keyCode: 40, modifiers: HotkeyModifiers.hyper.rawValue).summary,
            "Press \u{2726} K")
        XCTAssertEqual(MacroStep.wait(seconds: 0.5).summary, "Wait 0.5s")
    }
}
