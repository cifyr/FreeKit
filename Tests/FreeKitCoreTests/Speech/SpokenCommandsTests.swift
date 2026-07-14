import XCTest
@testable import FreeKitCore

final class SpokenCommandsTests: XCTestCase {
    func testNewLineBecomesNewline() {
        XCTAssertEqual(
            SpokenCommands.apply(to: "first item new line second item"),
            "first item\nSecond item")
    }

    func testNewParagraphBecomesDoubleNewline() {
        XCTAssertEqual(
            SpokenCommands.apply(to: "intro done. New paragraph. the details follow"),
            "intro done.\n\nThe details follow")
    }

    func testWhisperPunctuationAroundCommandIsConsumed() {
        XCTAssertEqual(
            SpokenCommands.apply(to: "thanks, new line. best regards"),
            "thanks\nBest regards")
    }

    func testScratchThatDropsEverythingBefore() {
        XCTAssertEqual(
            SpokenCommands.apply(to: "send it tomorrow scratch that send it today"),
            "send it today")
    }

    func testScratchThatAloneYieldsEmpty() {
        XCTAssertEqual(SpokenCommands.apply(to: "Scratch that."), "")
    }

    func testOrdinarySpeechIsUntouched() {
        XCTAssertEqual(
            SpokenCommands.apply(to: "the new lineup looks great"),
            "the new lineup looks great")
    }

    func testCapitalizesAfterInsertedNewline() {
        let out = SpokenCommands.apply(to: "alpha new paragraph beta")
        XCTAssertEqual(out, "alpha\n\nBeta")
    }
}

final class FillerWordsTests: XCTestCase {
    func testFillersAreStripped() {
        XCTAssertEqual(
            FillerWords.strip("um so uh we should, uhm, ship it"),
            "so we should, ship it")
    }

    func testWordsContainingFillersSurvive() {
        XCTAssertEqual(FillerWords.strip("the umbrella is uhuru's"), "the umbrella is uhuru's")
    }

    func testPunctuationTightenedAfterStrip() {
        XCTAssertEqual(FillerWords.strip("yes um , exactly"), "yes, exactly")
    }
}

final class TextReplacementsTests: XCTestCase {
    func testRulesApplyOnWordBoundaries() {
        let rules = [(from: "cadence", to: "Caden's")]
        XCTAssertEqual(
            TextReplacements.apply(rules: rules, to: "check cadence repo"),
            "check Caden's repo")
        XCTAssertEqual(
            TextReplacements.apply(rules: rules, to: "the cadences remain"),
            "the cadences remain")
    }

    func testEmptyFromIsIgnored() {
        XCTAssertEqual(TextReplacements.apply(rules: [(from: "", to: "x")], to: "abc"), "abc")
    }
}
