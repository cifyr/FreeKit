import XCTest
@testable import FreeKitCore

final class ModelCatalogTests: XCTestCase {
    func testRecommendedIsCompactTurbo() {
        XCTAssertEqual(ModelCatalog.recommendedID, "large-v3-turbo-q5_0")
        XCTAssertTrue(ModelCatalog.info(for: "large-v3-turbo-q5_0").recommended)
        XCTAssertEqual(ModelCatalog.known.filter(\.recommended).count, 1)
    }

    func testOrderedPutsRecommendedFirstAndUnknownsLast() {
        let ordered = ModelCatalog.ordered(["tiny.en", "mystery-model", "large-v3-turbo-q5_0", "base.en"])
        XCTAssertEqual(ordered.first?.id, "large-v3-turbo-q5_0")
        XCTAssertEqual(ordered.last?.id, "mystery-model")
    }

    func testUnknownModelFallsBackToRawName() {
        let info = ModelCatalog.info(for: "some-custom.bin")
        XCTAssertEqual(info.name, "some-custom.bin")
        XCTAssertFalse(info.recommended)
    }

    func testRatingsAreInRange() {
        for m in ModelCatalog.known {
            XCTAssertTrue((1...5).contains(m.accuracy), "\(m.id) accuracy out of range")
            XCTAssertTrue((1...5).contains(m.speed), "\(m.id) speed out of range")
        }
    }
}
