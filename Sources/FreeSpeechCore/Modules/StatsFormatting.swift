import Foundation

// Number formatting for the Stats menu, pure so it is unit-testable.
public enum StatsFormatting {
    // 1024-based, matching what Activity Monitor reports for throughput.
    public static func bytesPerSecond(_ bytes: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(0, bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%.\(fractionDigits(value, unit: unit))f %@", value, units[unit])
    }

    public static func bytes(_ count: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = max(0, count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%.\(fractionDigits(value, unit: unit))f %@", value, units[unit])
    }

    // One decimal only where it adds information: small non-whole scaled values.
    private static func fractionDigits(_ value: Double, unit: Int) -> Int {
        (value >= 100 || unit == 0 || value.rounded() == value) ? 0 : 1
    }

    public static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return String(format: "%.0f%%", clamped * 100)
    }

    // Per-core usage as a compact bar strip (one glyph per core).
    public static func coreBars(_ usages: [Double]) -> String {
        let levels: [Character] = ["\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}",
                                   "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}"]
        return String(usages.map { usage in
            let clamped = min(max(usage, 0), 1)
            let index = min(levels.count - 1, Int(clamped * Double(levels.count)))
            return levels[index]
        })
    }

    // Battery-style durations from minutes: "2h 05m", "34m".
    public static func minutes(_ total: Int) -> String {
        guard total > 0 else { return "\u{2014}" }
        let hours = total / 60
        let mins = total % 60
        return hours > 0 ? String(format: "%dh %02dm", hours, mins) : "\(mins)m"
    }

    // Compact uptime: the two most significant units only.
    public static func uptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    // Per-interface counters wrap and interfaces come and go; a negative delta
    // (counter reset, interface re-created) must clamp to zero, not go backwards.
    public static func throughput(previous: UInt64, current: UInt64,
                                  seconds: TimeInterval) -> Double {
        guard seconds > 0, current >= previous else { return 0 }
        return Double(current - previous) / seconds
    }
}
