import XCTest
@testable import FreeKitCore

final class ScreenContextTests: XCTestCase {
    func testNameFromEmailReplyIsExtracted() {
        let text = "On Tuesday, Gurkaran wrote: can you send the deck? Thanks, Gurkaran"
        XCTAssertTrue(ScreenContext.properNouns(in: text).contains("Gurkaran"))
    }

    func testMultiWordNameIsKeptTogether() {
        let text = "meeting with Gurkaran Singh about the roadmap"
        XCTAssertEqual(ScreenContext.properNouns(in: text), ["Gurkaran Singh"])
    }

    func testEmailAddressLocalPartIsExtracted() {
        let text = "to: gurkaran@example.com about the launch"
        XCTAssertTrue(ScreenContext.properNouns(in: text).contains("Gurkaran"))
    }

    func testSentenceInitialLoneWordIsIgnored() {
        // "Send" is just sentence casing, not vocabulary.
        let text = "Send the report today. Make it quick."
        XCTAssertTrue(ScreenContext.properNouns(in: text).isEmpty)
    }

    func testStoplistWordsAreIgnored() {
        let text = "Hi there. Thanks for the update. Best regards. The Inbox."
        XCTAssertTrue(ScreenContext.properNouns(in: text).isEmpty)
    }

    func testFrequencyRanking() {
        let text = "ping Zurich once. then Gurkaran said hello and Gurkaran left with Gurkaran"
        let terms = ScreenContext.properNouns(in: text, limit: 2)
        XCTAssertEqual(terms.first, "Gurkaran")
    }

    func testLimitIsRespected() {
        let text = "met Alice then Bob then Carol then Dave then Erin then Frank"
        XCTAssertEqual(ScreenContext.properNouns(in: text, limit: 3).count, 3)
    }

    func testMidSentenceProductNameIsExtracted() {
        let text = "we shipped it using FreeSpeech yesterday"
        XCTAssertEqual(ScreenContext.properNouns(in: text), ["FreeSpeech"])
    }
}
