import XCTest
@testable import FreeKitCore

final class SpeakerSplitterTests: XCTestCase {
    private func piece(_ start: Double, _ text: String, end: Double? = nil) -> TimedSegment {
        TimedSegment(start: start, end: end, text: text)
    }

    func testTurnInsertsLineBreakAtWordBoundary() {
        let out = SpeakerSplitter.merged(
            pieces: [
                piece(0.0, " we"), piece(0.4, " should"), piece(0.8, " ship."),
                piece(4.2, " that"), piece(4.6, " works."),
            ],
            turnTimes: [4.1])
        XCTAssertEqual(out, "We should ship.\nThat works.")
    }

    func testNoTurnsReconstructsTextVerbatim() {
        let out = SpeakerSplitter.merged(
            pieces: [piece(0, " first"), piece(1, " part,"), piece(2, " second"), piece(3, " part.")],
            turnTimes: [])
        XCTAssertEqual(out, "First part, second part.")
    }

    // Whisper's segments can span 10+ seconds; a turn inside one must still
    // split — this is the exact failure the word-level rewrite fixes.
    func testTurnInsideLongSegmentSplitsMidSegment() {
        let out = SpeakerSplitter.merged(
            pieces: [
                piece(0.0, " could"), piece(0.5, " you"), piece(1.0, " explain?"),
                piece(9.0, " I'll"), piece(9.5, " take"), piece(10.0, " a"), piece(10.3, " look."),
            ],
            turnTimes: [8.8])
        XCTAssertEqual(out, "Could you explain?\nI'll take a look.")
    }

    func testTurnMidWordDefersToNextWordBoundary() {
        // Subword pieces (no leading space) never get split apart.
        let out = SpeakerSplitter.merged(
            pieces: [piece(0.0, " un"), piece(0.3, "believ"), piece(0.5, "able."), piece(2.0, " yes.")],
            turnTimes: [0.4])
        XCTAssertEqual(out, "Unbelievable.\nYes.")
    }

    func testMultipleTurns() {
        let out = SpeakerSplitter.merged(
            pieces: [piece(0, " one."), piece(3, " two."), piece(6, " three.")],
            turnTimes: [2.9, 5.9])
        XCTAssertEqual(out, "One.\nTwo.\nThree.")
    }

    func testTurnBeforeFirstWordIsIgnored() {
        let out = SpeakerSplitter.merged(
            pieces: [piece(1.0, " only"), piece(1.4, " line.")],
            turnTimes: [0.5])
        XCTAssertEqual(out, "Only line.")
    }

    func testToleranceDoesNotBreakAWordEarly() {
        // Turn at 5.0 with the previous speaker's last word at 4.6: the break
        // must land before "hi" (5.4), not before "bye." (4.6).
        let out = SpeakerSplitter.merged(
            pieces: [piece(4.0, " ok"), piece(4.6, " bye."), piece(5.4, " hi"), piece(5.8, " there.")],
            turnTimes: [5.0])
        XCTAssertEqual(out, "Ok bye.\nHi there.")
    }

    func testTurnInsideLastWordStaysAfterThatWord() {
        let out = SpeakerSplitter.merged(
            pieces: [
                piece(4.0, " ok", end: 4.3),
                piece(4.8, " bye.", end: 5.15),
                piece(5.4, " hi", end: 5.7),
            ],
            turnTimes: [5.0])
        XCTAssertEqual(out, "Ok bye.\nHi")
    }

    func testSlightlyLateTurnStillBreaksBeforeNewSpeakerWord() {
        let out = SpeakerSplitter.merged(
            pieces: [
                piece(4.0, " ok", end: 4.3),
                piece(5.05, " hi", end: 5.3),
            ],
            turnTimes: [5.12])
        XCTAssertEqual(out, "Ok\nHi")
    }
}

final class CleanPreservingLinesTests: XCTestCase {
    func testLinesSurviveCleanup() {
        XCTAssertEqual(
            TranscriptCleaner.cleanPreservingLines(" first  line \nsecond [BLANK_AUDIO] line "),
            "first line\nsecond line")
    }

    func testAllNoiseLinesYieldNil() {
        XCTAssertNil(TranscriptCleaner.cleanPreservingLines("[BLANK_AUDIO]\n(wind blowing)"))
    }

    func testNoiseOnlyLineIsDropped() {
        XCTAssertEqual(
            TranscriptCleaner.cleanPreservingLines("real words\n[MUSIC]"),
            "real words")
    }
}
