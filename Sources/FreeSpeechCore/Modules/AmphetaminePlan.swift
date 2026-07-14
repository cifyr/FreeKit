import Foundation

// Session math for the Amphetamine keep-awake tool, kept pure so durations,
// countdowns, and the sleep-vector policy are testable without actually putting a
// Mac to sleep. The IOKit assertions and the privileged clamshell flip live
// app-side; the decisions about what to hold down live here.
public struct AmphetaminePlan: Equatable {
    public enum Duration: Equatable, Hashable {
        case minutes(Int)
        case indefinite

        // Menu order, shortest first. `.indefinite` is the right-click case.
        public static let presets: [Duration] = [
            .minutes(5), .minutes(15), .minutes(30),
            .minutes(60), .minutes(120), .minutes(300), .indefinite,
        ]

        public var seconds: TimeInterval? {
            switch self {
            case .minutes(let m): return TimeInterval(max(1, m)) * 60
            case .indefinite: return nil
            }
        }

        public var displayName: String {
            switch self {
            case .indefinite:
                return "Until I stop"
            case .minutes(let m) where m >= 60 && m % 60 == 0:
                let hours = m / 60
                return hours == 1 ? "1 hour" : "\(hours) hours"
            case .minutes(let m):
                return "\(m) minutes"
            }
        }
    }

    // The three independent sleep paths macOS can take. They are not
    // interchangeable: an assertion vetoes only *idle* transitions, so closing the
    // lid still forces sleep no matter what is asserted.
    public struct Vectors: Equatable {
        public var systemIdleSleep: Bool   // kIOPMAssertionTypePreventUserIdleSystemSleep
        public var displayIdleSleep: Bool  // kIOPMAssertionTypePreventUserIdleDisplaySleep
        public var clamshellSleep: Bool    // SleepDisabled system setting; root only

        public init(systemIdleSleep: Bool, displayIdleSleep: Bool, clamshellSleep: Bool) {
            self.systemIdleSleep = systemIdleSleep
            self.displayIdleSleep = displayIdleSleep
            self.clamshellSleep = clamshellSleep
        }
    }

    // A lid-closed session on battery with nothing draining it is how a laptop
    // cooks itself in a bag, so a session that survives the lid also gets a floor.
    public static let defaultBatteryFloorPercent = 20

    public var duration: Duration
    public var keepDisplayAwake: Bool
    public var keepAwakeWithLidClosed: Bool
    // nil disables the floor entirely.
    public var batteryFloorPercent: Int?

    public init(duration: Duration,
                keepDisplayAwake: Bool = true,
                keepAwakeWithLidClosed: Bool = false,
                batteryFloorPercent: Int? = defaultBatteryFloorPercent) {
        self.duration = duration
        self.keepDisplayAwake = keepDisplayAwake
        self.keepAwakeWithLidClosed = keepAwakeWithLidClosed
        self.batteryFloorPercent = batteryFloorPercent.map { min(max($0, 0), 100) }
    }

    public func vectors() -> Vectors {
        // Lid-closed mode forces the display-idle assertion on even if the user
        // left "keep display awake" off: with the lid shut, the idle-display-
        // sleep timer would otherwise fire on its own, and a display-sleep
        // transition is exactly what makes loginwindow lock the screen (and
        // stops video decoding). Holding this assertion is what lets a video keep
        // playing behind a closed lid without a password prompt on reopen.
        Vectors(systemIdleSleep: true,
                displayIdleSleep: keepDisplayAwake || keepAwakeWithLidClosed,
                clamshellSleep: keepAwakeWithLidClosed)
    }

    // nil means the session runs until stopped.
    public func remaining(elapsed: TimeInterval) -> TimeInterval? {
        guard let total = duration.seconds else { return nil }
        return max(0, total - elapsed)
    }

    public func isExpired(elapsed: TimeInterval) -> Bool {
        guard let total = duration.seconds else { return false }
        return elapsed >= total
    }

    // The floor only applies off AC: on the charger the battery is not the risk.
    public func shouldEndForBattery(percent: Int, onACPower: Bool) -> Bool {
        guard keepAwakeWithLidClosed, !onACPower, let floor = batteryFloorPercent else {
            return false
        }
        return percent <= floor
    }

    // Menu bar countdown. Indefinite sessions show a static glyph rather than a
    // number that never moves.
    public static func countdownText(remaining: TimeInterval?) -> String {
        guard let remaining else { return "\u{221E}" }
        let total = Int(remaining.rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
