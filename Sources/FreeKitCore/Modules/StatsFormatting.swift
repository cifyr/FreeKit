import Foundation

// Battery reading for one paired accessory or Apple device — AirPods, Magic
// Mouse/Keyboard/Trackpad (HID-over-Bluetooth), or an iPhone/iPad/Apple Watch
// read via lockdownd/companion_proxy (see IDeviceBatteryReader.swift). One
// merged list either way; nothing downstream needs to know which path found it.
public struct DeviceBattery: Equatable, Identifiable {
    public let name: String
    public let percent: Int

    public var id: String { name }

    public init(name: String, percent: Int) {
        self.name = name
        self.percent = percent
    }
}

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

    public static let lowDeviceBatteryThreshold = 20

    // Lowest battery first: whichever device needs attention should be the
    // first thing the dropdown/settings list shows, not buried alphabetically.
    public static func sortedDeviceBatteries(_ batteries: [DeviceBattery]) -> [DeviceBattery] {
        batteries.sorted { lhs, rhs in
            lhs.percent != rhs.percent ? lhs.percent < rhs.percent : lhs.name < rhs.name
        }
    }

    public static func isLowDeviceBattery(_ percent: Int) -> Bool {
        percent <= lowDeviceBatteryThreshold
    }

    // SF Symbol name stepped to the nearest battery glyph tier Apple ships.
    public static func deviceBatterySymbolName(percent: Int) -> String {
        switch clampPercent(percent) {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // Menu bar glyph: plain outline normally, the low-tier glyph the moment
    // any paired device is at or below the low-battery threshold.
    public static func deviceStatusItemSymbolName(for batteries: [DeviceBattery]) -> String {
        batteries.contains { isLowDeviceBattery($0.percent) } ? "battery.25percent" : "battery.100percent"
    }

    // Best-effort device-kind icon from the accessory's reported name, so a
    // device list reads at a glance instead of every row looking identical.
    public static func deviceIconSymbolName(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods") || lower.contains("earpods") { return "airpodspro" }
        if lower.contains("beats") { return "headphones" }
        if lower.contains("trackpad") { return "trackpad" }
        if lower.contains("mouse") { return "computermouse" }
        if lower.contains("keyboard") { return "keyboard" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("watch") { return "applewatch" }
        return "dot.radiowaves.left.and.right"
    }

    private static func clampPercent(_ percent: Int) -> Int {
        min(max(percent, 0), 100)
    }
}
