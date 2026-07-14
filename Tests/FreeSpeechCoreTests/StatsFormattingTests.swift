import XCTest
@testable import FreeSpeechCore

final class StatsFormattingTests: XCTestCase {
    func testBytesPerSecondUnits() {
        XCTAssertEqual(StatsFormatting.bytesPerSecond(0), "0 B/s")
        XCTAssertEqual(StatsFormatting.bytesPerSecond(512), "512 B/s")
        XCTAssertEqual(StatsFormatting.bytesPerSecond(1536), "1.5 KB/s")
        XCTAssertEqual(StatsFormatting.bytesPerSecond(1024 * 1024 * 2.5), "2.5 MB/s")
        // Three digits drop the decimal to keep menu rows compact.
        XCTAssertEqual(StatsFormatting.bytesPerSecond(1024 * 250), "250 KB/s")
        XCTAssertEqual(StatsFormatting.bytesPerSecond(-10), "0 B/s")
    }

    func testBytesUnits() {
        XCTAssertEqual(StatsFormatting.bytes(1024 * 1024 * 1024 * 18), "18 GB")
        XCTAssertEqual(StatsFormatting.bytes(1024 * 1024 * 1.2), "1.2 MB")
    }

    func testPercentClampsAndRounds() {
        XCTAssertEqual(StatsFormatting.percent(0.427), "43%")
        XCTAssertEqual(StatsFormatting.percent(0), "0%")
        XCTAssertEqual(StatsFormatting.percent(1.7), "100%")
        XCTAssertEqual(StatsFormatting.percent(-0.2), "0%")
    }

    func testCoreBarsMapUsageToLevels() {
        XCTAssertEqual(StatsFormatting.coreBars([0, 0.5, 1.0]), "\u{2581}\u{2585}\u{2588}")
        XCTAssertEqual(StatsFormatting.coreBars([]), "")
        // Out-of-range values clamp instead of crashing the strip.
        XCTAssertEqual(StatsFormatting.coreBars([-1, 2]), "\u{2581}\u{2588}")
    }

    func testMinutesFormatting() {
        XCTAssertEqual(StatsFormatting.minutes(34), "34m")
        XCTAssertEqual(StatsFormatting.minutes(125), "2h 05m")
        // Unknown (-1) and zero read as an em dash, not "0m".
        XCTAssertEqual(StatsFormatting.minutes(-1), "\u{2014}")
        XCTAssertEqual(StatsFormatting.minutes(0), "\u{2014}")
    }

    func testUptimeUsesTwoMostSignificantUnits() {
        XCTAssertEqual(StatsFormatting.uptime(59), "0m")
        XCTAssertEqual(StatsFormatting.uptime(35 * 60), "35m")
        XCTAssertEqual(StatsFormatting.uptime(3 * 3600 + 4 * 60), "3h 4m")
        XCTAssertEqual(StatsFormatting.uptime(2 * 86_400 + 5 * 3600 + 30 * 60), "2d 5h")
        XCTAssertEqual(StatsFormatting.uptime(-10), "0m")
    }

    func testThroughputDelta() {
        XCTAssertEqual(StatsFormatting.throughput(previous: 1000, current: 3000, seconds: 2), 1000)
        // Counter reset (interface bounced) must clamp to zero, not go negative.
        XCTAssertEqual(StatsFormatting.throughput(previous: 5000, current: 100, seconds: 1), 0)
        XCTAssertEqual(StatsFormatting.throughput(previous: 0, current: 100, seconds: 0), 0)
    }

    func testSortedDeviceBatteriesOrdersByLowestFirst() {
        let batteries = [
            DeviceBattery(name: "Magic Mouse", percent: 80),
            DeviceBattery(name: "AirPods Pro", percent: 15),
            DeviceBattery(name: "Magic Keyboard", percent: 45),
        ]
        let sorted = StatsFormatting.sortedDeviceBatteries(batteries)
        XCTAssertEqual(sorted.map(\.name), ["AirPods Pro", "Magic Keyboard", "Magic Mouse"])
    }

    func testSortedDeviceBatteriesTiesBreakByName() {
        let batteries = [
            DeviceBattery(name: "Magic Trackpad", percent: 50),
            DeviceBattery(name: "AirPods Max", percent: 50),
        ]
        let sorted = StatsFormatting.sortedDeviceBatteries(batteries)
        XCTAssertEqual(sorted.map(\.name), ["AirPods Max", "Magic Trackpad"])
    }

    func testIsLowDeviceBatteryThreshold() {
        XCTAssertTrue(StatsFormatting.isLowDeviceBattery(20))
        XCTAssertTrue(StatsFormatting.isLowDeviceBattery(5))
        XCTAssertFalse(StatsFormatting.isLowDeviceBattery(21))
        XCTAssertFalse(StatsFormatting.isLowDeviceBattery(100))
    }

    func testDeviceBatterySymbolNameTierBoundaries() {
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 0), "battery.0percent")
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 12), "battery.0percent")
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 13), "battery.25percent")
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 37), "battery.25percent")
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 38), "battery.50percent")
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 62), "battery.50percent")
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 63), "battery.75percent")
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 87), "battery.75percent")
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 88), "battery.100percent")
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 100), "battery.100percent")
        // Out-of-range clamps instead of crashing.
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: -10), "battery.0percent")
        XCTAssertEqual(StatsFormatting.deviceBatterySymbolName(percent: 999), "battery.100percent")
    }

    func testDeviceStatusItemSymbolReflectsLowestBattery() {
        let healthy = [DeviceBattery(name: "Magic Mouse", percent: 80)]
        XCTAssertEqual(StatsFormatting.deviceStatusItemSymbolName(for: healthy), "battery.100percent")

        let oneLow = [DeviceBattery(name: "Magic Mouse", percent: 80), DeviceBattery(name: "AirPods", percent: 10)]
        XCTAssertEqual(StatsFormatting.deviceStatusItemSymbolName(for: oneLow), "battery.25percent")

        XCTAssertEqual(StatsFormatting.deviceStatusItemSymbolName(for: []), "battery.100percent")
    }

    func testDeviceIconSymbolNameMatchesKnownKinds() {
        XCTAssertEqual(StatsFormatting.deviceIconSymbolName(for: "Caden's AirPods Pro"), "airpodspro")
        XCTAssertEqual(StatsFormatting.deviceIconSymbolName(for: "Beats Solo3"), "headphones")
        XCTAssertEqual(StatsFormatting.deviceIconSymbolName(for: "Magic Trackpad"), "trackpad")
        XCTAssertEqual(StatsFormatting.deviceIconSymbolName(for: "Magic Mouse 2"), "computermouse")
        XCTAssertEqual(StatsFormatting.deviceIconSymbolName(for: "Magic Keyboard"), "keyboard")
        XCTAssertEqual(StatsFormatting.deviceIconSymbolName(for: "Caden's iPhone"), "iphone")
        XCTAssertEqual(StatsFormatting.deviceIconSymbolName(for: "Caden's iPad"), "ipad")
        XCTAssertEqual(StatsFormatting.deviceIconSymbolName(for: "Caden's Apple Watch"), "applewatch")
        XCTAssertEqual(StatsFormatting.deviceIconSymbolName(for: "Unknown Gadget"), "dot.radiowaves.left.and.right")
    }
}
