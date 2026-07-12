import XCTest
@testable import FreeSpeechCore

final class ShelfPlanTests: XCTestCase {
    private let config = ShelfPlan.Sensitivity.medium.config

    // Zigzag with 30pt swings every 50ms: reversals land well inside the window.
    private func runZigzag(detector: inout ShakeDetector, swings: Int,
                           amplitude: Double, secondsPerSwing: Double,
                           startTime: TimeInterval = 0) -> Bool {
        var time = startTime
        var x = 0.0
        var fired = false
        for swing in 0..<swings {
            x += swing.isMultiple(of: 2) ? amplitude : -amplitude
            time += secondsPerSwing
            if detector.addSample(x: x, time: time) { fired = true }
        }
        return fired
    }

    func testVigorousWiggleFires() {
        var detector = ShakeDetector(config: config)
        _ = detector.addSample(x: 0, time: 0)
        XCTAssertTrue(runZigzag(detector: &detector, swings: 8, amplitude: 30,
                                secondsPerSwing: 0.05))
    }

    func testStraightDragNeverFires() {
        var detector = ShakeDetector(config: config)
        for step in 0..<200 {
            XCTAssertFalse(detector.addSample(x: Double(step) * 15,
                                              time: Double(step) * 0.02))
        }
    }

    func testSmallJitterNeverFires() {
        var detector = ShakeDetector(config: config)
        _ = detector.addSample(x: 0, time: 0)
        // 5pt flips are hand tremor, far below the 22pt medium swing floor.
        XCTAssertFalse(runZigzag(detector: &detector, swings: 40, amplitude: 5,
                                 secondsPerSwing: 0.03))
    }

    func testSlowZigzagFallsOutOfWindow() {
        var detector = ShakeDetector(config: config)
        _ = detector.addSample(x: 0, time: 0)
        // Big swings, but 0.5s apart: at most two reversals ever share the 0.9s window.
        XCTAssertFalse(runZigzag(detector: &detector, swings: 12, amplitude: 40,
                                 secondsPerSwing: 0.5))
    }

    func testFiresOnlyOncePerShakeThenRearms() {
        var detector = ShakeDetector(config: config)
        _ = detector.addSample(x: 0, time: 0)
        XCTAssertTrue(runZigzag(detector: &detector, swings: 8, amplitude: 30,
                                secondsPerSwing: 0.05))
        // Detector reset itself on fire; a fresh vigorous shake fires again.
        _ = detector.addSample(x: 0, time: 10)
        XCTAssertTrue(runZigzag(detector: &detector, swings: 8, amplitude: 30,
                                secondsPerSwing: 0.05, startTime: 10))
    }

    func testResetClearsProgress() {
        var detector = ShakeDetector(config: config)
        _ = detector.addSample(x: 0, time: 0)
        _ = runZigzag(detector: &detector, swings: 3, amplitude: 30, secondsPerSwing: 0.05)
        detector.reset()
        // Three more swings alone cannot reach the four-reversal floor if the
        // earlier progress was truly discarded.
        _ = detector.addSample(x: 0, time: 1)
        XCTAssertFalse(runZigzag(detector: &detector, swings: 3, amplitude: 30,
                                 secondsPerSwing: 0.05, startTime: 1))
    }

    func testHigherSensitivityFiresOnGentlerShake() {
        var eager = ShakeDetector(config: ShelfPlan.Sensitivity.high.config)
        var strict = ShakeDetector(config: ShelfPlan.Sensitivity.low.config)
        _ = eager.addSample(x: 0, time: 0)
        _ = strict.addSample(x: 0, time: 0)
        XCTAssertTrue(runZigzag(detector: &eager, swings: 5, amplitude: 18,
                                secondsPerSwing: 0.06))
        XCTAssertFalse(runZigzag(detector: &strict, swings: 5, amplitude: 18,
                                 secondsPerSwing: 0.06))
    }

    func testConfigClampsDegenerateValues() {
        let config = ShakeDetector.Config(minReversals: 0, window: 0, minSwing: -5)
        XCTAssertEqual(config.minReversals, 2)
        XCTAssertEqual(config.window, 0.1)
        XCTAssertEqual(config.minSwing, 1)
    }
}
