import XCTest
@testable import FreeKitCore

final class CoachPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let panel = CGSize(width: 340, height: 96)

    func testCentersBelowTheTargetWindow() {
        let target = CGRect(x: 400, y: 300, width: 700, height: 500)
        let pos = CoachPlacement.position(panelSize: panel, targetFrame: target, screenFrame: screen)
        XCTAssertTrue(pos.below)
        XCTAssertEqual(pos.origin.x, target.midX - panel.width / 2, accuracy: 0.5)
        XCTAssertEqual(pos.origin.y, target.minY - CoachPlacement.gap - panel.height, accuracy: 0.5)
    }

    func testFlipsAboveWhenWindowHugsScreenBottom() {
        let target = CGRect(x: 400, y: 10, width: 700, height: 500)
        let pos = CoachPlacement.position(panelSize: panel, targetFrame: target, screenFrame: screen)
        XCTAssertFalse(pos.below)
        XCTAssertEqual(pos.origin.y, target.maxY + CoachPlacement.gap, accuracy: 0.5)
    }

    func testClampsToLeftScreenEdge() {
        let target = CGRect(x: -200, y: 300, width: 400, height: 400)
        let pos = CoachPlacement.position(panelSize: panel, targetFrame: target, screenFrame: screen)
        XCTAssertEqual(pos.origin.x, screen.minX + CoachPlacement.screenInset, accuracy: 0.5)
    }

    func testClampsToRightScreenEdge() {
        let target = CGRect(x: 1300, y: 300, width: 400, height: 400)
        let pos = CoachPlacement.position(panelSize: panel, targetFrame: target, screenFrame: screen)
        XCTAssertEqual(
            pos.origin.x, screen.maxX - panel.width - CoachPlacement.screenInset, accuracy: 0.5)
    }

    func testAbovePlacementStaysOnScreenForTallWindows() {
        let target = CGRect(x: 400, y: 5, width: 700, height: 860)
        let pos = CoachPlacement.position(panelSize: panel, targetFrame: target, screenFrame: screen)
        XCTAssertFalse(pos.below)
        XCTAssertLessThanOrEqual(pos.origin.y + panel.height, screen.maxY)
        XCTAssertGreaterThanOrEqual(pos.origin.y, screen.minY)
    }

    func testFallbackSitsTopCenter() {
        let origin = CoachPlacement.fallbackOrigin(panelSize: panel, screenFrame: screen)
        XCTAssertEqual(origin.x, screen.midX - panel.width / 2, accuracy: 0.5)
        XCTAssertEqual(origin.y, screen.maxY - panel.height - 48, accuracy: 0.5)
    }
}
