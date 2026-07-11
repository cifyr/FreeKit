import XCTest
@testable import FreeSpeechCore

final class NotebookStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notebook-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testUpsertAndReload() {
        let store = NotebookStore(directory: directory)
        let rich = Data("fake rtf bytes".utf8)
        let note = Note(title: "Groceries", plainText: "milk\neggs", rich: rich)
        store.upsert(note)

        // A fresh store instance must read the same note back from disk,
        // including the opaque rich blob.
        let reloaded = NotebookStore(directory: directory)
        XCTAssertEqual(reloaded.count, 1)
        let restored = reloaded.note(id: note.id)
        XCTAssertEqual(restored?.title, "Groceries")
        XCTAssertEqual(restored?.plainText, "milk\neggs")
        XCTAssertEqual(restored?.rich, rich)
    }

    func testUpsertOverwritesExistingNote() {
        let store = NotebookStore(directory: directory)
        var note = Note(title: "v1", plainText: "one")
        store.upsert(note)
        note.title = "v2"
        note.plainText = "two"
        store.upsert(note)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.note(id: note.id)?.title, "v2")
    }

    func testNotesSortNewestModifiedFirst() {
        let store = NotebookStore(directory: directory)
        store.upsert(Note(title: "old", modified: Date(timeIntervalSince1970: 100)))
        store.upsert(Note(title: "new", modified: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(store.notes().map(\.title), ["new", "old"])
    }

    func testNotesCanSortByTitle() {
        let store = NotebookStore(directory: directory)
        store.upsert(Note(title: "Zulu", modified: Date(timeIntervalSince1970: 300)))
        store.upsert(Note(title: "alpha", modified: Date(timeIntervalSince1970: 100)))
        store.upsert(Note(title: "Bravo", modified: Date(timeIntervalSince1970: 200)))

        XCTAssertEqual(
            store.notes(sortedBy: .title).map(\.title),
            ["alpha", "Bravo", "Zulu"])
    }

    func testSearchMatchesTitleAndContentCaseInsensitive() {
        let store = NotebookStore(directory: directory)
        store.upsert(Note(title: "Meeting notes", plainText: "discuss roadmap"))
        store.upsert(Note(title: "Recipes", plainText: "Pasta with ROADMAP sauce"))
        store.upsert(Note(title: "Empty", plainText: "nothing here"))

        XCTAssertEqual(store.search("roadmap").count, 2)
        XCTAssertEqual(store.search("MEETING").map(\.title), ["Meeting notes"])
        XCTAssertEqual(store.search("absent").count, 0)
        // Blank query returns everything.
        XCTAssertEqual(store.search("  ").count, 3)
    }

    func testSearchPreservesRequestedSortOrder() {
        let store = NotebookStore(directory: directory)
        store.upsert(Note(title: "Zulu match", plainText: "x"))
        store.upsert(Note(title: "Alpha match", plainText: "x"))

        XCTAssertEqual(
            store.search("match", sortedBy: .title).map(\.title),
            ["Alpha match", "Zulu match"])
    }

    func testDeleteRemovesFromDisk() {
        let store = NotebookStore(directory: directory)
        let note = Note(title: "temp")
        store.upsert(note)
        store.delete(id: note.id)
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(NotebookStore(directory: directory).count, 0)
    }

    func testCorruptFileIsSkippedNotFatal() throws {
        let store = NotebookStore(directory: directory)
        store.upsert(Note(title: "good"))
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("garbage.json"))
        let reloaded = NotebookStore(directory: directory)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.notes().first?.title, "good")
    }
}
