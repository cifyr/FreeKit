import XCTest
@testable import FreeKitCore

final class HistoryStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-test-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func entry(_ text: String, at ts: TimeInterval) -> HistoryEntry {
        HistoryEntry(
            timestamp: Date(timeIntervalSince1970: ts), text: text,
            appName: "Notes", source: "microphone")
    }

    func testAppendAndRecentNewestFirst() {
        let store = HistoryStore(fileURL: url)
        store.append(entry("first", at: 1))
        store.append(entry("second", at: 2))
        XCTAssertEqual(store.recent().map(\.text), ["second", "first"])
    }

    func testPersistsAcrossInstances() {
        HistoryStore(fileURL: url).append(entry("kept", at: 1))
        XCTAssertEqual(HistoryStore(fileURL: url).recent().map(\.text), ["kept"])
    }

    func testSearchFiltersTextAndApp() {
        let store = HistoryStore(fileURL: url)
        store.append(entry("ship the release", at: 1))
        store.append(entry("grocery list", at: 2))
        XCTAssertEqual(store.recent(matching: "release").count, 1)
        XCTAssertEqual(store.recent(matching: "notes").count, 2)
        XCTAssertEqual(store.recent(matching: "zzz").count, 0)
    }

    func testCapIsEnforced() {
        let store = HistoryStore(fileURL: url)
        for i in 0..<(HistoryStore.maxEntries + 150) {
            store.append(entry("t\(i)", at: TimeInterval(i)))
        }
        XCTAssertLessThanOrEqual(store.count, HistoryStore.maxEntries + 100)
        let reloaded = HistoryStore(fileURL: url)
        XCTAssertLessThanOrEqual(reloaded.count, HistoryStore.maxEntries)
        XCTAssertEqual(reloaded.recent().first?.text, "t\(HistoryStore.maxEntries + 149)")
    }

    func testClear() {
        let store = HistoryStore(fileURL: url)
        store.append(entry("x", at: 1))
        store.clear()
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(HistoryStore(fileURL: url).count, 0)
    }
}
