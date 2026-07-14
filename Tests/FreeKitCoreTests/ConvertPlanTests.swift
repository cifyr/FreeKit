import XCTest
@testable import FreeKitCore

final class ConvertPlanTests: XCTestCase {
    // MARK: - mediaKind classification

    func testMediaKindClassifiesEveryExtensionFamily() {
        XCTAssertEqual(ConvertPlan.mediaKind(forFileExtension: "png"), .image)
        XCTAssertEqual(ConvertPlan.mediaKind(forFileExtension: "JPG"), .image)
        XCTAssertEqual(ConvertPlan.mediaKind(forFileExtension: "wav"), .audio)
        XCTAssertEqual(ConvertPlan.mediaKind(forFileExtension: "M4A"), .audio)
        XCTAssertEqual(ConvertPlan.mediaKind(forFileExtension: "mp4"), .video)
        XCTAssertEqual(ConvertPlan.mediaKind(forFileExtension: "mov"), .video)
        XCTAssertEqual(ConvertPlan.mediaKind(forFileExtension: "docx"), .document)
        XCTAssertEqual(ConvertPlan.mediaKind(forFileExtension: "rtf"), .document)
        XCTAssertEqual(ConvertPlan.mediaKind(forFileExtension: "pdf"), .pdf)
        XCTAssertEqual(ConvertPlan.mediaKind(forFileExtension: "PDF"), .pdf)
    }

    func testMediaKindNilForUnknownExtension() {
        XCTAssertNil(ConvertPlan.mediaKind(forFileExtension: "exe"))
        XCTAssertNil(ConvertPlan.mediaKind(forFileExtension: ""))
    }

    // Extension sets must be disjoint: nothing should map to two kinds at once.
    func testExtensionSetsAreDisjoint() {
        let sets: [ConvertPlan.MediaKind: Set<String>] = [
            .image: ConvertPlan.imageExtensions,
            .audio: ConvertPlan.audioExtensions,
            .video: ConvertPlan.videoExtensions,
            .document: ConvertPlan.documentExtensions,
            .pdf: ConvertPlan.pdfExtensions,
        ]
        for (kindA, extsA) in sets {
            for (kindB, extsB) in sets where kindA != kindB {
                XCTAssertTrue(extsA.isDisjoint(with: extsB), "\(kindA) and \(kindB) overlap")
            }
        }
    }

    // MARK: - needsConversion

    func testNeedsConversionComparesCaseInsensitively() {
        XCTAssertFalse(ConvertPlan.needsConversion(currentExtension: "JPG", targetExtension: "jpg"))
        XCTAssertTrue(ConvertPlan.needsConversion(currentExtension: "png", targetExtension: "jpg"))
    }

    // MARK: - Target.outputExtension

    func testTargetOutputExtensionPicksPerKind() {
        let target = ConvertPlan.Target(
            image: .heic, audio: .wav, video: .mov, document: .docx, pdf: .plainText)
        XCTAssertEqual(target.outputExtension(forSourceExtension: "png"), "heic")
        XCTAssertEqual(target.outputExtension(forSourceExtension: "m4a"), "wav")
        XCTAssertEqual(target.outputExtension(forSourceExtension: "mp4"), "mov")
        XCTAssertEqual(target.outputExtension(forSourceExtension: "rtf"), "docx")
        XCTAssertEqual(target.outputExtension(forSourceExtension: "pdf"), "txt")
    }

    func testTargetOutputExtensionNilForUnrecognizedSource() {
        let target = ConvertPlan.Target()
        XCTAssertNil(target.outputExtension(forSourceExtension: "exe"))
    }

    // MARK: - Format display/extension tables

    func testImageFormatExtensions() {
        XCTAssertEqual(ConvertPlan.ImageFormat.png.fileExtension, "png")
        XCTAssertEqual(ConvertPlan.ImageFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ConvertPlan.ImageFormat.heic.fileExtension, "heic")
        XCTAssertEqual(ConvertPlan.ImageFormat.tiff.fileExtension, "tiff")
        XCTAssertEqual(ConvertPlan.ImageFormat.bmp.fileExtension, "bmp")
        XCTAssertEqual(ConvertPlan.ImageFormat.pdf.fileExtension, "pdf")
    }

    func testVideoFormatsShareMP4ExtensionExceptMov() {
        XCTAssertEqual(ConvertPlan.VideoFormat.mp4H264.fileExtension, "mp4")
        XCTAssertEqual(ConvertPlan.VideoFormat.mp4HEVC.fileExtension, "mp4")
        XCTAssertEqual(ConvertPlan.VideoFormat.mov.fileExtension, "mov")
    }

    func testEveryCaseHasADisplayName() {
        for value in ConvertPlan.ImageFormat.allCases { XCTAssertFalse(value.displayName.isEmpty) }
        for value in ConvertPlan.AudioFormat.allCases { XCTAssertFalse(value.displayName.isEmpty) }
        for value in ConvertPlan.VideoFormat.allCases { XCTAssertFalse(value.displayName.isEmpty) }
        for value in ConvertPlan.DocumentFormat.allCases { XCTAssertFalse(value.displayName.isEmpty) }
        for value in ConvertPlan.PDFTarget.allCases { XCTAssertFalse(value.displayName.isEmpty) }
        for value in ConvertPlan.FileDestination.allCases { XCTAssertFalse(value.displayName.isEmpty) }
    }

    // MARK: - Naming

    func testSiblingNameAppendsConvertedSuffix() {
        let url = URL(fileURLWithPath: "/tmp/photos/photo.png")
        let sibling = ConvertPlan.siblingURL(for: url, targetExtension: "jpg") { _ in false }
        XCTAssertEqual(sibling.path, "/tmp/photos/photo (converted).jpg")
    }

    func testSiblingNameDedupesWhenTaken() {
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        let taken: Set<String> = [
            "/tmp/photo (converted).jpg", "/tmp/photo (converted 2).jpg",
        ]
        let sibling = ConvertPlan.siblingURL(for: url, targetExtension: "jpg") { taken.contains($0.path) }
        XCTAssertEqual(sibling.path, "/tmp/photo (converted 3).jpg")
    }

    func testReplacementURLSwapsExtensionInPlace() {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        let replaced = ConvertPlan.replacementURL(for: url, targetExtension: "jpg") { _ in false }
        XCTAssertEqual(replaced.path, "/tmp/shot.jpg")
    }

    // A collision with an unrelated existing file falls back to the sibling
    // naming rather than silently overwriting it.
    func testReplacementURLFallsBackToSiblingOnCollision() {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        let taken: Set<String> = ["/tmp/shot.jpg"]
        let replaced = ConvertPlan.replacementURL(for: url, targetExtension: "jpg") { taken.contains($0.path) }
        XCTAssertEqual(replaced.path, "/tmp/shot (converted).jpg")
    }

    func testBackupURLPreservesFilename() {
        let url = URL(fileURLWithPath: "/Users/x/Desktop/deck.docx")
        let dir = URL(fileURLWithPath: "/tmp/convert-backups")
        let backup = ConvertPlan.backupURL(for: url, in: dir) { _ in false }
        XCTAssertEqual(backup.path, "/tmp/convert-backups/deck.docx")
    }

    func testBackupURLDedupesCollisions() {
        let url = URL(fileURLWithPath: "/Users/x/deck.docx")
        let dir = URL(fileURLWithPath: "/tmp/convert-backups")
        let taken: Set<String> = ["/tmp/convert-backups/deck.docx"]
        let backup = ConvertPlan.backupURL(for: url, in: dir) { taken.contains($0.path) }
        XCTAssertEqual(backup.path, "/tmp/convert-backups/deck 2.docx")
    }

    func testPageNumberedURLAppendsPageSuffix() {
        let url = URL(fileURLWithPath: "/tmp/docs/report.pdf")
        let page = ConvertPlan.pageNumberedURL(for: url, page: 3, targetExtension: "jpg") { _ in false }
        XCTAssertEqual(page.path, "/tmp/docs/report-page-3.jpg")
    }

    func testPageNumberedURLDedupesCollisions() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        let taken: Set<String> = ["/tmp/report-page-1.jpg"]
        let page = ConvertPlan.pageNumberedURL(for: url, page: 1, targetExtension: "jpg") { taken.contains($0.path) }
        XCTAssertEqual(page.path, "/tmp/report-page-1 (2).jpg")
    }

    func testCombinedPDFURLUsesBaseName() {
        let dir = URL(fileURLWithPath: "/tmp/photos")
        let combined = ConvertPlan.combinedPDFURL(baseName: "Combined", in: dir) { _ in false }
        XCTAssertEqual(combined.path, "/tmp/photos/Combined.pdf")
    }

    func testCombinedPDFURLDedupesCollisions() {
        let dir = URL(fileURLWithPath: "/tmp/photos")
        let taken: Set<String> = ["/tmp/photos/Combined.pdf"]
        let combined = ConvertPlan.combinedPDFURL(baseName: "Combined", in: dir) { taken.contains($0.path) }
        XCTAssertEqual(combined.path, "/tmp/photos/Combined 2.pdf")
    }
}
