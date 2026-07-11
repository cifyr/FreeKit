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

    // Per-interface counters wrap and interfaces come and go; a negative delta
    // (counter reset, interface re-created) must clamp to zero, not go backwards.
    public static func throughput(previous: UInt64, current: UInt64,
                                  seconds: TimeInterval) -> Double {
        guard seconds > 0, current >= previous else { return 0 }
        return Double(current - previous) / seconds
    }
}
