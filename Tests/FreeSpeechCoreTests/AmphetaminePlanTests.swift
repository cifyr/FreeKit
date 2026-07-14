import XCTest
@testable import FreeSpeechCore

final class AmphetaminePlanTests: XCTestCase {
    func testDurationSeconds() {
        XCTAssertEqual(AmphetaminePlan.Duration.minutes(5).seconds, 300)
        XCTAssertEqual(AmphetaminePlan.Duration.minutes(120).seconds, 7200)
        XCTAssertNil(AmphetaminePlan.Duration.indefinite.seconds)
    }

    func testDurationDisplayNames() {
        XCTAssertEqual(AmphetaminePlan.Duration.minutes(5).displayName, "5 minutes")
        XCTAssertEqual(AmphetaminePlan.Duration.minutes(60).displayName, "1 hour")
        XCTAssertEqual(AmphetaminePlan.Duration.minutes(120).displayName, "2 hours")
        XCTAssertEqual(AmphetaminePlan.Duration.minutes(90).displayName, "90 minutes")
        XCTAssertEqual(AmphetaminePlan.Duration.indefinite.displayName, "Until I stop")
    }

    func testPresetsRunShortestFirstAndEndIndefinite() {
        let presets = AmphetaminePlan.Duration.presets
        XCTAssertEqual(presets.first, .minutes(5))
        XCTAssertEqual(presets.last, .indefinite)
        let finite = presets.compactMap(\.seconds)
        XCTAssertEqual(finite, finite.sorted())
    }

    func testSystemIdleSleepIsAlwaysHeld() {
        let plan = AmphetaminePlan(duration: .minutes(30), keepDisplayAwake: false)
        XCTAssertTrue(plan.vectors().systemIdleSleep)
    }

    func testDisplayVectorFollowsKeepDisplayAwake() {
        XCTAssertTrue(AmphetaminePlan(duration: .minutes(30), keepDisplayAwake: true)
            .vectors().displayIdleSleep)
        XCTAssertFalse(AmphetaminePlan(duration: .minutes(30), keepDisplayAwake: false)
            .vectors().displayIdleSleep)
    }

    func testClamshellVectorFollowsLidClosedToggle() {
        XCTAssertFalse(AmphetaminePlan(duration: .indefinite, keepAwakeWithLidClosed: false)
            .vectors().clamshellSleep)
        XCTAssertTrue(AmphetaminePlan(duration: .indefinite, keepAwakeWithLidClosed: true)
            .vectors().clamshellSleep)
    }

    // Lid-closed must hold the display assertion even with "keep display awake"
    // off: an idle display-sleep behind a closed lid is what triggers the lock
    // and stops video, so the two are not independent in that combination.
    func testLidClosedForcesDisplayAssertionEvenWhenDisplayAwakeIsOff() {
        let plan = AmphetaminePlan(duration: .indefinite,
                                   keepDisplayAwake: false,
                                   keepAwakeWithLidClosed: true)
        XCTAssertTrue(plan.vectors().displayIdleSleep)
    }

    func testRemainingCountsDown() {
        let plan = AmphetaminePlan(duration: .minutes(5))
        XCTAssertEqual(plan.remaining(elapsed: 0), 300)
        XCTAssertEqual(plan.remaining(elapsed: 120), 180)
        XCTAssertEqual(plan.remaining(elapsed: 300), 0)
    }

    func testRemainingNeverGoesNegative() {
        let plan = AmphetaminePlan(duration: .minutes(5))
        XCTAssertEqual(plan.remaining(elapsed: 9_999), 0)
    }

    func testIndefiniteSessionHasNoRemainingAndNeverExpires() {
        let plan = AmphetaminePlan(duration: .indefinite)
        XCTAssertNil(plan.remaining(elapsed: 86_400))
        XCTAssertFalse(plan.isExpired(elapsed: 86_400))
    }

    func testExpiryAtBoundary() {
        let plan = AmphetaminePlan(duration: .minutes(1))
        XCTAssertFalse(plan.isExpired(elapsed: 59.9))
        XCTAssertTrue(plan.isExpired(elapsed: 60))
        XCTAssertTrue(plan.isExpired(elapsed: 61))
    }

    func testBatteryFloorEndsLidClosedSessionOffAC() {
        let plan = AmphetaminePlan(duration: .indefinite,
                                   keepAwakeWithLidClosed: true,
                                   batteryFloorPercent: 20)
        XCTAssertFalse(plan.shouldEndForBattery(percent: 21, onACPower: false))
        XCTAssertTrue(plan.shouldEndForBattery(percent: 20, onACPower: false))
        XCTAssertTrue(plan.shouldEndForBattery(percent: 5, onACPower: false))
    }

    func testBatteryFloorIgnoredOnACPower() {
        let plan = AmphetaminePlan(duration: .indefinite,
                                   keepAwakeWithLidClosed: true,
                                   batteryFloorPercent: 20)
        XCTAssertFalse(plan.shouldEndForBattery(percent: 3, onACPower: true))
    }

    // A lid-open session cannot strand the Mac in a bag, so the floor does not
    // apply to it.
    func testBatteryFloorIgnoredWhenLidClosedModeIsOff() {
        let plan = AmphetaminePlan(duration: .indefinite,
                                   keepAwakeWithLidClosed: false,
                                   batteryFloorPercent: 20)
        XCTAssertFalse(plan.shouldEndForBattery(percent: 1, onACPower: false))
    }

    func testBatteryFloorCanBeDisabled() {
        let plan = AmphetaminePlan(duration: .indefinite,
                                   keepAwakeWithLidClosed: true,
                                   batteryFloorPercent: nil)
        XCTAssertFalse(plan.shouldEndForBattery(percent: 1, onACPower: false))
    }

    func testBatteryFloorIsClamped() {
        XCTAssertEqual(AmphetaminePlan(duration: .indefinite, batteryFloorPercent: 140)
            .batteryFloorPercent, 100)
        XCTAssertEqual(AmphetaminePlan(duration: .indefinite, batteryFloorPercent: -5)
            .batteryFloorPercent, 0)
    }

    func testCountdownFormatting() {
        XCTAssertEqual(AmphetaminePlan.countdownText(remaining: 0), "0:00")
        XCTAssertEqual(AmphetaminePlan.countdownText(remaining: 59), "0:59")
        XCTAssertEqual(AmphetaminePlan.countdownText(remaining: 299), "4:59")
        XCTAssertEqual(AmphetaminePlan.countdownText(remaining: 3_600), "1:00:00")
        XCTAssertEqual(AmphetaminePlan.countdownText(remaining: 5_025), "1:23:45")
    }

    func testCountdownRoundsUpSoItNeverShowsZeroWhileRunning() {
        XCTAssertEqual(AmphetaminePlan.countdownText(remaining: 0.4), "0:01")
    }

    func testCountdownForIndefiniteSession() {
        XCTAssertEqual(AmphetaminePlan.countdownText(remaining: nil), "\u{221E}")
    }
}
