import XCTest
@testable import FreeKitCore

final class AutoclickPlanTests: XCTestCase {
    func testIntervalIsClampedToSafeBounds() {
        XCTAssertEqual(AutoclickPlan(interval: 0).interval, AutoclickPlan.minInterval)
        XCTAssertEqual(AutoclickPlan(interval: -3).interval, AutoclickPlan.minInterval)
        XCTAssertEqual(AutoclickPlan(interval: 9999).interval, AutoclickPlan.maxInterval)
        XCTAssertEqual(AutoclickPlan(interval: 0.25).interval, 0.25)
    }

    func testClicksPerSecondConversionRoundTrips() {
        XCTAssertEqual(AutoclickPlan.interval(clicksPerSecond: 10), 0.1, accuracy: 1e-9)
        XCTAssertEqual(AutoclickPlan(interval: 0.1).clicksPerSecond, 10, accuracy: 1e-9)
        // Nonsense CPS degrades to the slowest allowed pace, not a crash or flood.
        XCTAssertEqual(AutoclickPlan.interval(clicksPerSecond: 0), AutoclickPlan.maxInterval)
    }

    func testCountLimitStopCondition() {
        let plan = AutoclickPlan(interval: 0.1, maxClicks: 3)
        XCTAssertFalse(plan.isComplete(afterClicks: 0))
        XCTAssertFalse(plan.isComplete(afterClicks: 2))
        XCTAssertTrue(plan.isComplete(afterClicks: 3))
        XCTAssertTrue(plan.isComplete(afterClicks: 4))
    }

    func testUnlimitedPlanNeverCompletes() {
        let plan = AutoclickPlan(interval: 0.1, maxClicks: nil)
        XCTAssertFalse(plan.isComplete(afterClicks: 1_000_000))
    }

    func testMaxClicksFloorsAtOne() {
        XCTAssertEqual(AutoclickPlan(interval: 0.1, maxClicks: -5).maxClicks, 1)
    }

    func testClickTypePressesPerTick() {
        XCTAssertEqual(AutoclickPlan.ClickType.single.pressesPerTick, 1)
        XCTAssertEqual(AutoclickPlan.ClickType.double.pressesPerTick, 2)
    }

    func testPlanCarriesClickTypeAndSafetyFlag() {
        let plan = AutoclickPlan(
            interval: 0.1, clickType: .double, stopOnCursorMove: true)
        XCTAssertEqual(plan.clickType, .double)
        XCTAssertTrue(plan.stopOnCursorMove)
        // Defaults stay conservative: single click, no cursor guard.
        let defaults = AutoclickPlan(interval: 0.1)
        XCTAssertEqual(defaults.clickType, .single)
        XCTAssertFalse(defaults.stopOnCursorMove)
    }

    func testOptionalTimeLimit() {
        let unlimited = AutoclickPlan(interval: 0.1)
        XCTAssertFalse(unlimited.isTimeLimitReached(elapsed: 10_000))

        let limited = AutoclickPlan(interval: 0.1, maxDuration: 30)
        XCTAssertFalse(limited.isTimeLimitReached(elapsed: 29.9))
        XCTAssertTrue(limited.isTimeLimitReached(elapsed: 30))
    }

    func testTimeLimitFloorsAtOneSecond() {
        XCTAssertEqual(AutoclickPlan(interval: 0.1, maxDuration: -4).maxDuration, 1)
    }

    func testTickScheduleStartsImmediatelyAndSpacesByInterval() {
        let plan = AutoclickPlan(interval: 0.5)
        XCTAssertEqual(plan.tickTimes(count: 4), [0, 0.5, 1.0, 1.5])
        XCTAssertEqual(plan.tickTimes(count: 0), [])
    }
}
