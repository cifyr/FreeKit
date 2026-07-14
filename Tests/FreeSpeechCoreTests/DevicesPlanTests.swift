import XCTest
@testable import FreeSpeechCore

final class DevicesPlanTests: XCTestCase {
    func testSortedOrdersByLowestBatteryFirst() {
        let batteries = [
            DeviceBattery(name: "Magic Mouse", percent: 80),
            DeviceBattery(name: "AirPods Pro", percent: 15),
            DeviceBattery(name: "Magic Keyboard", percent: 45),
        ]
        let sorted = DevicesPlan.sorted(batteries)
        XCTAssertEqual(sorted.map(\.name), ["AirPods Pro", "Magic Keyboard", "Magic Mouse"])
    }

    func testSortedTiesBreakByName() {
        let batteries = [
            DeviceBattery(name: "Magic Trackpad", percent: 50),
            DeviceBattery(name: "AirPods Max", percent: 50),
        ]
        let sorted = DevicesPlan.sorted(batteries)
        XCTAssertEqual(sorted.map(\.name), ["AirPods Max", "Magic Trackpad"])
    }

    func testIsLowThreshold() {
        XCTAssertTrue(DevicesPlan.isLow(20))
        XCTAssertTrue(DevicesPlan.isLow(5))
        XCTAssertFalse(DevicesPlan.isLow(21))
        XCTAssertFalse(DevicesPlan.isLow(100))
    }

    func testPercentLabelClamps() {
        XCTAssertEqual(DevicesPlan.percentLabel(42), "42%")
        XCTAssertEqual(DevicesPlan.percentLabel(-5), "0%")
        XCTAssertEqual(DevicesPlan.percentLabel(140), "100%")
    }

    func testSymbolNameTierBoundaries() {
        XCTAssertEqual(DevicesPlan.symbolName(percent: 0), "battery.0percent")
        XCTAssertEqual(DevicesPlan.symbolName(percent: 12), "battery.0percent")
        XCTAssertEqual(DevicesPlan.symbolName(percent: 13), "battery.25percent")
        XCTAssertEqual(DevicesPlan.symbolName(percent: 37), "battery.25percent")
        XCTAssertEqual(DevicesPlan.symbolName(percent: 38), "battery.50percent")
        XCTAssertEqual(DevicesPlan.symbolName(percent: 62), "battery.50percent")
        XCTAssertEqual(DevicesPlan.symbolName(percent: 63), "battery.75percent")
        XCTAssertEqual(DevicesPlan.symbolName(percent: 87), "battery.75percent")
        XCTAssertEqual(DevicesPlan.symbolName(percent: 88), "battery.100percent")
        XCTAssertEqual(DevicesPlan.symbolName(percent: 100), "battery.100percent")
        // Out-of-range clamps instead of crashing.
        XCTAssertEqual(DevicesPlan.symbolName(percent: -10), "battery.0percent")
        XCTAssertEqual(DevicesPlan.symbolName(percent: 999), "battery.100percent")
    }

    func testStatusItemSymbolReflectsLowestBattery() {
        let healthy = [DeviceBattery(name: "Magic Mouse", percent: 80)]
        XCTAssertEqual(DevicesPlan.statusItemSymbolName(for: healthy), "battery.100percent")

        let oneLow = [DeviceBattery(name: "Magic Mouse", percent: 80), DeviceBattery(name: "AirPods", percent: 10)]
        XCTAssertEqual(DevicesPlan.statusItemSymbolName(for: oneLow), "battery.25percent")

        XCTAssertEqual(DevicesPlan.statusItemSymbolName(for: []), "battery.100percent")
    }

    func testDeviceIconSymbolNameMatchesKnownKinds() {
        XCTAssertEqual(DevicesPlan.deviceIconSymbolName(for: "Caden's AirPods Pro"), "airpodspro")
        XCTAssertEqual(DevicesPlan.deviceIconSymbolName(for: "Beats Solo3"), "headphones")
        XCTAssertEqual(DevicesPlan.deviceIconSymbolName(for: "Magic Trackpad"), "trackpad")
        XCTAssertEqual(DevicesPlan.deviceIconSymbolName(for: "Magic Mouse 2"), "computermouse")
        XCTAssertEqual(DevicesPlan.deviceIconSymbolName(for: "Magic Keyboard"), "keyboard")
        XCTAssertEqual(DevicesPlan.deviceIconSymbolName(for: "Caden's iPhone"), "iphone")
        XCTAssertEqual(DevicesPlan.deviceIconSymbolName(for: "Caden's iPad"), "ipad")
        XCTAssertEqual(DevicesPlan.deviceIconSymbolName(for: "Caden's Apple Watch"), "applewatch")
        XCTAssertEqual(DevicesPlan.deviceIconSymbolName(for: "Unknown Gadget"), "dot.radiowaves.left.and.right")
    }
}
