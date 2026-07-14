import Foundation

// Decision layer for the Shelf module, kept pure so the shake gesture is
// unit-testable. A "shake" is several horizontal direction reversals, each
// with real travel behind it, packed into a short window — jitter and normal
// dragging never qualify.
public enum ShelfPlan {
    // Continuous 0...1 dial (a slider, not presets). 0 = Low: needs a good
    // second of real, sizable shaking. 1 = High: almost any small wiggle
    // fires it. Reversal count and swing distance are what actually make it
    // easier or harder; window only shrinks a little at the High end so a
    // couple of tiny wiggles still read as "fast enough". At every setting
    // the window stays short enough that a slow, deliberate drag can never
    // accumulate enough in-window reversals to fire on its own.
    public static let defaultSensitivity = 0.5

    public static func config(forSensitivity value: Double) -> ShakeDetector.Config {
        let t = min(max(value, 0), 1)
        return ShakeDetector.Config(
            minReversals: Int((6 - 4 * t).rounded()),
            window: 0.9 - 0.3 * t,
            minSwing: 24 - 19 * t)
    }
}

public struct ShakeDetector {
    public struct Config: Equatable {
        public var minReversals: Int
        public var window: TimeInterval
        public var minSwing: Double

        public init(minReversals: Int, window: TimeInterval, minSwing: Double) {
            self.minReversals = max(2, minReversals)
            self.window = max(0.1, window)
            self.minSwing = max(1, minSwing)
        }
    }

    private let config: Config
    private var lastX: Double?
    private var direction = 0
    private var travel: Double = 0
    private var reversalTimes: [TimeInterval] = []

    public init(config: Config) {
        self.config = config
    }

    public mutating func reset() {
        lastX = nil
        direction = 0
        travel = 0
        reversalTimes = []
    }

    // Feed pointer samples; returns true exactly once when the shake fires,
    // then starts over. Only horizontal motion counts: a wiggle is side to
    // side, and vertical scroll-ish drags must not trigger it.
    public mutating func addSample(x: Double, time: TimeInterval) -> Bool {
        defer { lastX = x }
        guard let lastX else { return false }
        let dx = x - lastX
        guard dx != 0 else { return false }
        let newDirection = dx > 0 ? 1 : -1
        if direction == 0 || newDirection == direction {
            direction = newDirection
            travel += abs(dx)
            return false
        }
        // Direction flipped: the swing that just ended counts only if it
        // traveled far enough to be deliberate.
        if travel >= config.minSwing {
            reversalTimes.append(time)
            reversalTimes.removeAll { time - $0 > config.window }
            if reversalTimes.count >= config.minReversals {
                reset()
                return true
            }
        }
        direction = newDirection
        travel = abs(dx)
        return false
    }
}
