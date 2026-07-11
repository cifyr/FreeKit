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
}
