import XCTest
@testable import FreeKitCore

final class SmartInsertionTests: XCTestCase {
    // MARK: - Overlap dedup

    func testLeadingOverlapIsDropped() {
        XCTAssertEqual(
            SmartInsertion.overlapTrimmed(
                transcript: "let's meet at three Friday",
                textBeforeCaret: "I said let's meet at"),
            "three Friday")
    }

    func testOverlapIsCaseInsensitive() {
        XCTAssertEqual(
            SmartInsertion.overlapTrimmed(
                transcript: "Let's Meet At noon",
                textBeforeCaret: "ok let's meet at"),
            "noon")
    }

    func testNoOverlapKeepsTranscript() {
        XCTAssertEqual(
            SmartInsertion.overlapTrimmed(
                transcript: "ship it today",
                textBeforeCaret: "unrelated text"),
            "ship it today")
    }

    func testOverlapIgnoresPunctuationOnBoundary() {
        XCTAssertEqual(
            SmartInsertion.overlapTrimmed(
                transcript: "three o'clock works",
                textBeforeCaret: "How about three, o'clock?"),
            "works")
    }

    func testOverlapWindowIsCapped() {
        // Ten matching words, but only the last maxOverlapWords are considered;
        // the match inside the window still resolves.
        let phrase = "one two three four five six seven eight nine ten"
        XCTAssertEqual(
            SmartInsertion.overlapTrimmed(
                transcript: "three four five six seven eight nine ten go",
                textBeforeCaret: phrase),
            "go")
    }

    func testFullOverlapLeavesNothing() {
        XCTAssertEqual(
            SmartInsertion.overlapTrimmed(
                transcript: "see you soon",
                textBeforeCaret: "ok see you soon"),
            "")
    }

    func testRepeatedPhraseMidTranscriptIsNotTouched() {
        // Only the head of the transcript may be deduped.
        XCTAssertEqual(
            SmartInsertion.overlapTrimmed(
                transcript: "again and again",
                textBeforeCaret: "do it again"),
            "and again")
    }

    // MARK: - Casing and spacing

    func testMidSentenceContinuationIsLowercasedWithOneSpace() {
        XCTAssertEqual(
            SmartInsertion.applyCasingAndSpacing("We should ship", textBeforeCaret: "I think"),
            " we should ship")
        XCTAssertEqual(
            SmartInsertion.applyCasingAndSpacing("We should ship", textBeforeCaret: "I think "),
            "we should ship")
    }

    func testNewSentenceAfterTerminatorCapitalizes() {
        XCTAssertEqual(
            SmartInsertion.applyCasingAndSpacing("next up", textBeforeCaret: "Done. "),
            "Next up")
        XCTAssertEqual(
            SmartInsertion.applyCasingAndSpacing("next up", textBeforeCaret: "Done."),
            " Next up")
        XCTAssertEqual(
            SmartInsertion.applyCasingAndSpacing("next up", textBeforeCaret: "Really?"),
            " Next up")
    }

    func testNewlineStartsFreshSentenceWithoutLeadingSpace() {
        XCTAssertEqual(
            SmartInsertion.applyCasingAndSpacing("next item", textBeforeCaret: "list:\n"),
            "Next item")
    }

    func testEmptyFieldCapitalizesWithoutLeadingSpace() {
        XCTAssertEqual(
            SmartInsertion.applyCasingAndSpacing("hello there", textBeforeCaret: ""),
            "Hello there")
        XCTAssertEqual(
            SmartInsertion.applyCasingAndSpacing("hello there", textBeforeCaret: "   "),
            "Hello there")
    }

    func testPronounIIsNeverLowercased() {
        XCTAssertEqual(
            SmartInsertion.applyCasingAndSpacing("I agree with", textBeforeCaret: "and "),
            "I agree with")
        XCTAssertEqual(
            SmartInsertion.applyCasingAndSpacing("I'll do it", textBeforeCaret: "then "),
            "I'll do it")
    }

    // MARK: - Full pipeline

    func testPrepareCombinesDedupAndCasing() {
        XCTAssertEqual(
            SmartInsertion.prepare(
                transcript: "Let's meet at three Friday",
                textBeforeCaret: "let's meet at "),
            "three Friday")
    }

    func testPrepareUnreadableFieldFallsBackToPlainCapitalizedInsert() {
        XCTAssertEqual(
            SmartInsertion.prepare(transcript: "hello world", textBeforeCaret: nil),
            "Hello world")
    }

    func testPrepareEmptyTranscriptYieldsEmpty() {
        XCTAssertEqual(SmartInsertion.prepare(transcript: "  ", textBeforeCaret: "x"), "")
    }

    func testPrepareFullyDuplicatedTranscriptYieldsEmpty() {
        XCTAssertEqual(
            SmartInsertion.prepare(
                transcript: "see you soon",
                textBeforeCaret: "ok see you soon"),
            "")
    }
}
