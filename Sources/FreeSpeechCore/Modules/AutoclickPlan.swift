import Foundation

// Scheduling math for the Tap autoclicker, kept pure so tick pacing and stop
// conditions are unit-testable. "Tap" is interpreted as configurable
// fixed-interval clicking with an optional total-count limit (not
// hold-to-repeat or pattern playback).
public struct AutoclickPlan: Equatable {
    public enum Button: String, CaseIterable {
        case left, right

        public var displayName: String {
            switch self {
            case .left: return "Left"
            case .right: return "Right"
            }
        }
    }

    public enum ClickType: String, CaseIterable {
        case single, double

        public var displayName: String {
            switch self {
            case .single: return "Single"
            case .double: return "Double"
            }
        }

        // How many down/up pairs one tick posts (double-clicks pair two with
        // an increasing click state).
        public var pressesPerTick: Int {
            self == .double ? 2 : 1
        }
    }

    public enum Target: String, CaseIterable {
        case cursor
        case fixedPoint

        public var displayName: String {
            switch self {
            case .cursor: return "At cursor"
            case .fixedPoint: return "Fixed point"
            }
        }
    }

    // Bounds keep a mistyped interval from either freezing the machine with a
    // click flood or scheduling a click an hour out.
    public static let minInterval: TimeInterval = 0.02
    public static let maxInterval: TimeInterval = 60

    public var interval: TimeInterval
    // nil means "until stopped".
    public var maxClicks: Int?
    public var button: Button
    public var target: Target
    public var clickType: ClickType
    // Fixed-point safety: moving the physical cursor cancels the run.
    public var stopOnCursorMove: Bool

    public init(interval: TimeInterval, maxClicks: Int? = nil,
                button: Button = .left, target: Target = .cursor,
                clickType: ClickType = .single, stopOnCursorMove: Bool = false) {
        self.interval = min(max(interval, Self.minInterval), Self.maxInterval)
        self.maxClicks = maxClicks.map { max(1, $0) }
        self.button = button
        self.target = target
        self.clickType = clickType
        self.stopOnCursorMove = stopOnCursorMove
    }

    public var clicksPerSecond: Double { 1.0 / interval }

    public static func interval(clicksPerSecond: Double) -> TimeInterval {
        guard clicksPerSecond > 0 else { return maxInterval }
        return min(max(1.0 / clicksPerSecond, minInterval), maxInterval)
    }

    // True when the run should stop before performing click number `clickIndex`
    // (0-based), i.e. after `clickIndex` clicks already happened.
    public func isComplete(afterClicks performed: Int) -> Bool {
        guard let maxClicks else { return false }
        return performed >= maxClicks
    }

    // Fire times relative to start; first click fires immediately so a hotkey
    // press gives instant feedback.
    public func tickTimes(count: Int) -> [TimeInterval] {
        (0..<max(0, count)).map { Double($0) * interval }
    }
}
