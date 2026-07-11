import Foundation

// One note. `rich` is an opaque RTF blob produced by the app layer (RTF because
// it round-trips bold, color, and NSTextList bullets, and stays a documented
// format on disk); `plainText` is kept alongside it so search never has to
// parse RTF in Core.
public struct Note: Identifiable, Equatable, Codable {
    public let id: UUID
    public var title: String
    public var plainText: String
    public var rich: Data?
    public var modified: Date

    public init(id: UUID = UUID(), title: String = "", plainText: String = "",
                rich: Data? = nil, modified: Date = Date()) {
        self.id = id
        self.title = title
        self.plainText = plainText
        self.rich = rich
        self.modified = modified
    }
}

// Disk-backed notebook: one JSON file per note so a corrupt write can only ever
// lose a single note, and saves stay O(one note).
public final class NotebookStore {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.cadenwarren.freespeech.notebook")
    private var cache: [UUID: Note] = [:]

    public init(directory: URL) {
        self.directory = directory
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            do {
                let note = try decoder.decode(Note.self, from: Data(contentsOf: file))
                cache[note.id] = note
            } catch {
                Log.error("notebook: failed to load \(file.lastPathComponent): \(error)")
            }
        }
    }

    public var count: Int { queue.sync { cache.count } }

    // Newest modified first.
    public func notes() -> [Note] {
        queue.sync { cache.values.sorted { $0.modified > $1.modified } }
    }

    public func note(id: UUID) -> Note? {
        queue.sync { cache[id] }
    }

    public func search(_ query: String) -> [Note] {
        let all = notes()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.plainText.localizedCaseInsensitiveContains(query)
        }
    }

    public func upsert(_ note: Note) {
        queue.sync {
            cache[note.id] = note
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(note)
                try data.write(to: fileURL(for: note.id), options: .atomic)
            } catch {
                Log.error("notebook: save failed for note \(note.id): \(error)")
            }
        }
    }

    public func delete(id: UUID) {
        queue.sync {
            cache[id] = nil
            do {
                try FileManager.default.removeItem(at: fileURL(for: id))
            } catch CocoaError.fileNoSuchFile {
                // Never persisted; nothing to remove.
            } catch {
                Log.error("notebook: delete failed for note \(id): \(error)")
            }
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
