import Foundation

// Friendly, benched descriptions of the whisper models, so the picker communicates
// accuracy-vs-speed instead of raw ggml filenames. Ratings come from bench/results.json
// (greedy decode + vocabulary hint, M4 Max): accuracy tracks WER, speed tracks transcribe time.
public struct ModelInfo: Equatable {
    public let id: String        // ggml base name, e.g. "large-v3-turbo-q5_0"
    public let name: String      // friendly display name
    public let tagline: String   // one-line accuracy-vs-speed summary
    public let accuracy: Int     // 1...5, higher = more accurate (lower WER)
    public let speed: Int        // 1...5, higher = faster
    public let recommended: Bool

    public init(id: String, name: String, tagline: String,
                accuracy: Int, speed: Int, recommended: Bool) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.accuracy = accuracy
        self.speed = speed
        self.recommended = recommended
    }
}

public enum ModelCatalog {
    public static let recommendedID = "large-v3-turbo-q5_0"

    public static let known: [ModelInfo] = [
        ModelInfo(id: "large-v3-turbo-q5_0", name: "Turbo (compact)",
                  tagline: "Best accuracy, still fast", accuracy: 5, speed: 4, recommended: true),
        ModelInfo(id: "large-v3-turbo", name: "Large Turbo",
                  tagline: "High accuracy, large download", accuracy: 4, speed: 4, recommended: false),
        ModelInfo(id: "base.en", name: "Base",
                  tagline: "Good accuracy, very fast", accuracy: 3, speed: 5, recommended: false),
        ModelInfo(id: "medium.en", name: "Medium",
                  tagline: "Good accuracy, slower and large", accuracy: 3, speed: 2, recommended: false),
        ModelInfo(id: "small.en", name: "Small",
                  tagline: "Modest accuracy, fast", accuracy: 2, speed: 4, recommended: false),
        ModelInfo(id: "tiny.en", name: "Tiny",
                  tagline: "Roughest accuracy, fastest", accuracy: 1, speed: 5, recommended: false),
    ]

    // Unknown models (user-dropped ggml files) fall back to their raw name, mid ratings.
    public static func info(for id: String) -> ModelInfo {
        known.first { $0.id == id }
            ?? ModelInfo(id: id, name: id, tagline: "Whisper model",
                         accuracy: 3, speed: 3, recommended: false)
    }

    // Installed models ordered best-first by catalog rank; unknowns last, alphabetical.
    public static func ordered(_ installed: [String]) -> [ModelInfo] {
        let rank = Dictionary(uniqueKeysWithValues:
            known.enumerated().map { ($0.element.id, $0.offset) })
        return installed.map(info(for:)).sorted { a, b in
            let ra = rank[a.id] ?? Int.max
            let rb = rank[b.id] ?? Int.max
            return ra != rb ? ra < rb : a.id < b.id
        }
    }
}
