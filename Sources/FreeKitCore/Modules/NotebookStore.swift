import Foundation

public enum NotebookSortOrder: String, CaseIterable, Codable {
    case modified
    case title

    public var displayName: String {
        switch self {
        case .modified: return "Recently edited"
        case .title: return "Title"
        }
    }
}

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
    // The AppleScript id of the Apple Notes note this one was explicitly synced
    // with; nil for never-synced notes. Optional so pre-sync JSON decodes as-is.
    public var appleNoteID: String?

    public init(id: UUID = UUID(), title: String = "", plainText: String = "",
                rich: Data? = nil, modified: Date = Date(), appleNoteID: String? = nil) {
        self.id = id
        self.title = title
        self.plainText = plainText
        self.rich = rich
        self.modified = modified
        self.appleNoteID = appleNoteID
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

    public func notes(sortedBy order: NotebookSortOrder = .modified) -> [Note] {
        queue.sync {
            switch order {
            case .modified:
                return cache.values.sorted { $0.modified > $1.modified }
            case .title:
                return cache.values.sorted {
                    let lhs = $0.title.isEmpty ? "Untitled" : $0.title
                    let rhs = $1.title.isEmpty ? "Untitled" : $1.title
                    let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
                    return comparison == .orderedSame
                        ? $0.modified > $1.modified
                        : comparison == .orderedAscending
                }
            }
        }
    }

    public func note(id: UUID) -> Note? {
        queue.sync { cache[id] }
    }

    public func search(_ query: String, sortedBy order: NotebookSortOrder = .modified) -> [Note] {
        let all = notes(sortedBy: order)
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

// AppleScript sources for the optional Apple Notes sync, kept pure so the
// quoting and script shapes are testable without Automation consent or a
// running Notes.app. The app layer executes these via NSAppleScript (the
// suite's existing cross-app automation route; see Convert's Finder scripts).
public enum AppleNotesScript {
    // AppleScript string literals escape only backslash and double-quote.
    public static func quoted(_ raw: String) -> String {
        "\"" + raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // FreeKit-made notes live in their own Notes folder so users can tell
    // them apart from everything else in the app.
    public static let folderName = "FreeKit"

    // Creates (or, when existingID is set, updates) a note and returns its id.
    // Notes' `body` is HTML; the name is derived from the body's first line by
    // Notes itself when updating, so the title is folded into the body heading.
    public static func push(htmlBody: String, existingID: String?) -> String {
        if let existingID {
            return """
            tell application "Notes"
                set theNote to note id \(quoted(existingID))
                set body of theNote to \(quoted(htmlBody))
                return id of theNote
            end tell
            """
        }
        return """
        tell application "Notes"
            tell default account
                if not (exists folder "\(folderName)") then
                    make new folder with properties {name:"\(folderName)"}
                end if
                set theNote to make new note at folder "\(folderName)" with properties {body:\(quoted(htmlBody))}
                return id of theNote
            end tell
        end tell
        """
    }

    // Returns the note's HTML body; a missing id raises an AppleScript error
    // the app layer surfaces.
    public static func pull(id: String) -> String {
        """
        tell application "Notes"
            return body of note id \(quoted(id))
        end tell
        """
    }
}
