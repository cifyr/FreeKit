import Foundation

public struct HistoryEntry: Codable, Equatable, Identifiable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let text: String
    public let appName: String
    public let source: String

    public init(timestamp: Date, text: String, appName: String, source: String) {
        self.timestamp = timestamp
        self.text = text
        self.appName = appName
        self.source = source
    }
}

// Local-only transcript history: append-only JSONL, newest last on disk,
// capped so it can never grow unbounded.
public final class HistoryStore {
    public static let maxEntries = 500
    // Rewrites are amortized: only compact once the file overshoots by this much.
    private static let compactSlack = 100

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.cadenwarren.freespeech.history")
    private var entries: [HistoryEntry]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        var loaded: [HistoryEntry] = []
        if let data = try? String(contentsOf: fileURL, encoding: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for line in data.split(separator: "\n") {
                if let entry = try? decoder.decode(HistoryEntry.self, from: Data(line.utf8)) {
                    loaded.append(entry)
                }
            }
        }
        entries = Array(loaded.suffix(Self.maxEntries))
    }

    public var count: Int { queue.sync { entries.count } }

    // Newest first, optionally filtered by a case-insensitive substring.
    public func recent(matching query: String = "") -> [HistoryEntry] {
        queue.sync {
            let all = entries.reversed()
            guard !query.isEmpty else { return Array(all) }
            return all.filter {
                $0.text.localizedCaseInsensitiveContains(query)
                    || $0.appName.localizedCaseInsensitiveContains(query)
            }
        }
    }

    public func append(_ entry: HistoryEntry) {
        queue.sync {
            entries.append(entry)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                if entries.count > Self.maxEntries + Self.compactSlack {
                    entries = Array(entries.suffix(Self.maxEntries))
                    try rewriteAll(encoder: encoder)
                } else if let data = try? encoder.encode(entry) {
                    try appendLine(data)
                }
            } catch {
                Log.error("history append failed at \(fileURL.path): \(error)")
            }
        }
    }

    public func clear() {
        queue.sync {
            entries = []
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func appendLine(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    private func rewriteAll(encoder: JSONEncoder) throws {
        let lines = try entries.map { try encoder.encode($0) }
        var blob = Data()
        for line in lines {
            blob.append(line)
            blob.append(Data("\n".utf8))
        }
        try blob.write(to: fileURL, options: .atomic)
    }
}
