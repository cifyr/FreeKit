import XCTest
@testable import FreeSpeechCore

final class SpeakerSplitterTests: XCTestCase {
    private func seg(_ start: Double, _ text: String) -> TimedSegment {
        TimedSegment(start: start, text: text)
    }

    func testTurnInsertsLineBreak() {
        let out = SpeakerSplitter.merged(
            segments: [seg(0, "we should push the deadline."), seg(4.2, "that works for me.")],
            turnTimes: [4.1])
        XCTAssertEqual(out, "we should push the deadline.\nthat works for me.")
    }

    func testNoTurnsJoinsWithSpaces() {
        let out = SpeakerSplitter.merged(
            segments: [seg(0, "first part,"), seg(3, "second part.")],
            turnTimes: [])
        XCTAssertEqual(out, "first part, second part.")
    }

    func testToleranceAbsorbsTimestampDrift() {
        // Turn detected slightly after the segment boundary still splits there.
        let out = SpeakerSplitter.merged(
            segments: [seg(0, "hello."), seg(5.0, "hi there.")],
            turnTimes: [5.3])
        XCTAssertEqual(out, "hello.\nhi there.")
    }

    func testTurnWellInsideSegmentDoesNotSplitLater() {
        // A turn at 2s is consumed by the 5s boundary check only once.
        let out = SpeakerSplitter.merged(
            segments: [seg(0, "a."), seg(5, "b."), seg(10, "c.")],
            turnTimes: [4.8])
        XCTAssertEqual(out, "a.\nb. c.")
    }

    func testMultipleTurns() {
        let out = SpeakerSplitter.merged(
            segments: [seg(0, "one."), seg(3, "two."), seg(6, "three.")],
            turnTimes: [2.9, 5.9])
        XCTAssertEqual(out, "one.\ntwo.\nthree.")
    }

    func testTurnBeforeFirstSegmentIsIgnored() {
        let out = SpeakerSplitter.merged(
            segments: [seg(1, "only line.")],
            turnTimes: [0.5])
        XCTAssertEqual(out, "only line.")
    }

    func testEmptySegmentsAreSkipped() {
        let out = SpeakerSplitter.merged(
            segments: [seg(0, "start."), seg(2, "   "), seg(4, "end.")],
            turnTimes: [3.9])
        XCTAssertEqual(out, "start.\nend.")
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
