import XCTest
@testable import FreeKitCore

final class TranscriptCleanerTests: XCTestCase {
    func testTrimsWhitespace() {
        XCTAssertEqual(TranscriptCleaner.clean("  Hello world. \n"), "Hello world.")
    }

    func testDoesNotCapitalize() {
        // Casing is decided at insert time by SmartInsertion (caret context).
        XCTAssertEqual(TranscriptCleaner.clean("hello there"), "hello there")
    }

    func testBlankAudioMarkerYieldsNil() {
        XCTAssertNil(TranscriptCleaner.clean(" [BLANK_AUDIO]"))
        XCTAssertNil(TranscriptCleaner.clean("(wind blowing)"))
        XCTAssertNil(TranscriptCleaner.clean("♪♪"))
    }

    func testEmptyYieldsNil() {
        XCTAssertNil(TranscriptCleaner.clean(""))
        XCTAssertNil(TranscriptCleaner.clean("   \n "))
    }

    func testMarkerInsideSpeechIsStripped() {
        XCTAssertEqual(
            TranscriptCleaner.clean("send the report [BLANK_AUDIO] by Friday"),
            "send the report by Friday")
    }

    func testCollapsesInternalWhitespace() {
        XCTAssertEqual(TranscriptCleaner.clean("one  two\n three"), "one two three")
    }

    func testAlreadyCleanTextUnchanged() {
        XCTAssertEqual(
            TranscriptCleaner.clean("The quick brown fox."),
            "The quick brown fox.")
    }
}
