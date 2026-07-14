import Foundation

// Battery reading for one paired accessory (AirPods, Magic Mouse/Keyboard/
// Trackpad, and other HID-over-Bluetooth devices that publish BatteryPercent).
public struct DeviceBattery: Equatable, Identifiable {
    public let name: String
    public let percent: Int

    public var id: String { name }

    public init(name: String, percent: Int) {
        self.name = name
        self.percent = percent
    }
}

// Pure formatting/sorting for the Devices popup, kept separate from the IOKit
// scan (DevicesModule.swift) so it's testable without paired hardware.
public enum DevicesPlan {
    public static let lowBatteryThreshold = 20

    // Lowest battery first: whichever device needs attention should be the
    // first thing the popup shows, not buried alphabetically.
    public static func sorted(_ batteries: [DeviceBattery]) -> [DeviceBattery] {
        batteries.sorted { lhs, rhs in
            lhs.percent != rhs.percent ? lhs.percent < rhs.percent : lhs.name < rhs.name
        }
    }

    public static func isLow(_ percent: Int) -> Bool {
        percent <= lowBatteryThreshold
    }

    public static func percentLabel(_ percent: Int) -> String {
        "\(clamp(percent))%"
    }

    // SF Symbol name stepped to the nearest battery glyph tier Apple ships.
    public static func symbolName(percent: Int) -> String {
        switch clamp(percent) {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // Menu bar glyph: plain outline normally, the low-tier glyph the moment
    // any paired device is at or below the low-battery threshold.
    public static func statusItemSymbolName(for batteries: [DeviceBattery]) -> String {
        batteries.contains { isLow($0.percent) } ? "battery.25percent" : "battery.100percent"
    }

    // Best-effort device-kind icon from the accessory's reported name, so the
    // popup reads at a glance instead of every row looking identical.
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

    private static func clamp(_ percent: Int) -> Int {
        min(max(percent, 0), 100)
    }
}
