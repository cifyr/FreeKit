import XCTest
@testable import FreeSpeechCore

final class ClopPlanTests: XCTestCase {
    // MARK: - shouldProcess gate

    func testOwnWriteIsAlwaysSkippedFirst() {
        let plan = ClopPlan(imagesEnabled: true)
        XCTAssertEqual(plan.shouldProcess(type: .image, byteCount: 1_000_000, isOwnWrite: true),
                       .skip(.ownWrite))
    }

    func testDisabledTypeIsSkipped() {
        let plan = ClopPlan(imagesEnabled: true, videosEnabled: false, pdfsEnabled: false)
        XCTAssertEqual(plan.shouldProcess(type: .video, byteCount: 1_000_000, isOwnWrite: false),
                       .skip(.typeDisabled))
        XCTAssertEqual(plan.shouldProcess(type: .pdf, byteCount: 1_000_000, isOwnWrite: false),
                       .skip(.typeDisabled))
        XCTAssertEqual(plan.shouldProcess(type: .image, byteCount: 1_000_000, isOwnWrite: false),
                       .process)
    }

    func testSizeFloorSkipsTinyPayloads() {
        let plan = ClopPlan(skipBelowBytes: 10_240)
        XCTAssertEqual(plan.shouldProcess(type: .image, byteCount: 10_239, isOwnWrite: false),
                       .skip(.belowSizeFloor))
        XCTAssertEqual(plan.shouldProcess(type: .image, byteCount: 10_240, isOwnWrite: false),
                       .process)
    }

    func testDefaultsWatchImagesOnly() {
        let plan = ClopPlan()
        XCTAssertTrue(plan.isEnabled(.image))
        XCTAssertFalse(plan.isEnabled(.video))
        XCTAssertFalse(plan.isEnabled(.pdf))
    }

    // MARK: - Clamping

    func testQualityAndSavingsAreClamped() {
        let low = ClopPlan(quality: -1, minimumSavings: -0.5)
        XCTAssertEqual(low.quality, ClopPlan.qualityRange.lowerBound)
        XCTAssertEqual(low.minimumSavings, 0)
        let high = ClopPlan(quality: 3, minimumSavings: 5)
        XCTAssertEqual(high.quality, 1)
        XCTAssertEqual(high.minimumSavings, ClopPlan.minimumSavingsRange.upperBound)
    }

    func testTinyMaxDimensionMeansOff() {
        XCTAssertNil(ClopPlan(maxDimension: 10).maxDimension)
        XCTAssertEqual(ClopPlan(maxDimension: 1440).maxDimension, 1440)
        XCTAssertNil(ClopPlan(maxDimension: nil).maxDimension)
    }

    func testNegativeSizeFloorClampsToZero() {
        XCTAssertEqual(ClopPlan(skipBelowBytes: -5).skipBelowBytes, 0)
    }

    // MARK: - targetSize

    func testTargetSizeFitsLongestEdge() {
        let landscape = ClopPlan.targetSize(width: 4000, height: 3000, maxDimension: 2000)
        XCTAssertEqual(landscape.width, 2000)
        XCTAssertEqual(landscape.height, 1500)
        let portrait = ClopPlan.targetSize(width: 1080, height: 2400, maxDimension: 1200)
        XCTAssertEqual(portrait.width, 540)
        XCTAssertEqual(portrait.height, 1200)
    }

    func testTargetSizeNeverUpscales() {
        let size = ClopPlan.targetSize(width: 800, height: 600, maxDimension: 2160)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    func testTargetSizeWithNoCapReturnsOriginal() {
        let size = ClopPlan.targetSize(width: 5000, height: 5000, maxDimension: nil)
        XCTAssertEqual(size.width, 5000)
        XCTAssertEqual(size.height, 5000)
    }

    func testTargetSizeDegenerateInputs() {
        let zero = ClopPlan.targetSize(width: 0, height: 100, maxDimension: 50)
        XCTAssertEqual(zero.width, 0)
        XCTAssertEqual(zero.height, 100)
        // Extreme aspect ratios still land on at least one pixel.
        let sliver = ClopPlan.targetSize(width: 10_000, height: 1, maxDimension: 100)
        XCTAssertEqual(sliver.width, 100)
        XCTAssertEqual(sliver.height, 1)
    }

    // MARK: - keepResult

    func testKeepResultRequiresMinimumSavings() {
        XCTAssertTrue(ClopPlan.keepResult(originalBytes: 1000, optimizedBytes: 900,
                                          minimumSavings: 0.10))
        XCTAssertFalse(ClopPlan.keepResult(originalBytes: 1000, optimizedBytes: 901,
                                           minimumSavings: 0.10))
    }

    func testKeepResultRejectsEqualOrLarger() {
        XCTAssertFalse(ClopPlan.keepResult(originalBytes: 1000, optimizedBytes: 1000,
                                           minimumSavings: 0))
        XCTAssertFalse(ClopPlan.keepResult(originalBytes: 1000, optimizedBytes: 1200,
                                           minimumSavings: 0))
    }

    func testZeroMinimumSavingsStillRequiresStrictlySmaller() {
        XCTAssertTrue(ClopPlan.keepResult(originalBytes: 1000, optimizedBytes: 999,
                                          minimumSavings: 0))
    }

    func testKeepResultRejectsBrokenSizes() {
        XCTAssertFalse(ClopPlan.keepResult(originalBytes: 0, optimizedBytes: 0, minimumSavings: 0))
        XCTAssertFalse(ClopPlan.keepResult(originalBytes: 1000, optimizedBytes: 0, minimumSavings: 0))
        XCTAssertFalse(ClopPlan.keepResult(originalBytes: -1, optimizedBytes: -2, minimumSavings: 0))
    }

    func testInstanceKeepResultUsesPlanFloor() {
        let plan = ClopPlan(minimumSavings: 0.5)
        XCTAssertTrue(plan.keepResult(originalBytes: 1000, optimizedBytes: 500))
        XCTAssertFalse(plan.keepResult(originalBytes: 1000, optimizedBytes: 501))
    }

    // MARK: - Filenames

    func testSiblingNameAppendsCloppedSuffix() {
        let url = URL(fileURLWithPath: "/tmp/photos/photo.png")
        let sibling = ClopPlan.siblingURL(for: url) { _ in false }
        XCTAssertEqual(sibling.path, "/tmp/photos/photo (clopped).png")
    }

    func testSiblingNameDedupesWhenTaken() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let taken: Set<String> = ["/tmp/photo (clopped).jpg", "/tmp/photo (clopped 2).jpg"]
        let sibling = ClopPlan.siblingURL(for: url) { taken.contains($0.path) }
        XCTAssertEqual(sibling.path, "/tmp/photo (clopped 3).jpg")
    }

    func testSiblingNameSwapsExtensionOnConversion() {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        let sibling = ClopPlan.siblingURL(for: url, preferredExtension: "jpg") { _ in false }
        XCTAssertEqual(sibling.path, "/tmp/shot (clopped).jpg")
    }

    func testSiblingNameHandlesExtensionlessFiles() {
        let url = URL(fileURLWithPath: "/tmp/README")
        let sibling = ClopPlan.siblingURL(for: url) { _ in false }
        XCTAssertEqual(sibling.path, "/tmp/README (clopped)")
    }

    func testBackupURLPreservesFilename() {
        let url = URL(fileURLWithPath: "/Users/x/Desktop/deck.pdf")
        let dir = URL(fileURLWithPath: "/tmp/clop-backups")
        let backup = ClopPlan.backupURL(for: url, in: dir) { _ in false }
        XCTAssertEqual(backup.path, "/tmp/clop-backups/deck.pdf")
    }

    func testBackupURLDedupesCollisions() {
        let url = URL(fileURLWithPath: "/Users/x/deck.pdf")
        let dir = URL(fileURLWithPath: "/tmp/clop-backups")
        let taken: Set<String> = ["/tmp/clop-backups/deck.pdf"]
        let backup = ClopPlan.backupURL(for: url, in: dir) { taken.contains($0.path) }
        XCTAssertEqual(backup.path, "/tmp/clop-backups/deck 2.pdf")
    }

    // MARK: - Savings summary

    func testSavingsSummaryFormatsBytesAndPercent() {
        // 2 MB -> 736 KB saves 1.28 MB (64%).
        let summary = ClopPlan.savingsSummary(originalBytes: 2_097_152, optimizedBytes: 754_975)
        XCTAssertEqual(summary, "Saved 1.3 MB (64%)")
    }

    func testSavingsSummaryNeverGoesNegative() {
        let summary = ClopPlan.savingsSummary(originalBytes: 100, optimizedBytes: 200)
        XCTAssertEqual(summary, "Saved 0 B (0%)")
    }
}
