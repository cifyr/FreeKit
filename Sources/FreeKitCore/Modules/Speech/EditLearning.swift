import Foundation

// Extracts correction pairs from how the user edited inserted text: word-level
// LCS diff between the field right after insertion and the field a while later.
public enum EditDiff {
    // Fields larger than this are skipped: LCS is quadratic and huge fields mean
    // the dictation is a tiny fraction of the text anyway.
    public static let maxWords = 1500
    private static let maxRunLength = 6

    public static func corrections(
        inserted: String, before: String, after: String
    ) -> [(from: String, to: String)] {
        let beforeTokens = tokenize(before)
        let afterTokens = tokenize(after)
        guard !beforeTokens.isEmpty, !afterTokens.isEmpty,
              beforeTokens.count <= maxWords, afterTokens.count <= maxWords else { return [] }

        let insertedNorm = " " + tokenize(inserted).map(\.norm).joined(separator: " ") + " "
        var pairs: [(String, String)] = []

        for (removed, added) in substitutionRuns(beforeTokens, afterTokens) {
            guard removed.count <= maxRunLength, added.count <= maxRunLength,
                  !removed.isEmpty, !added.isEmpty else { continue }
            let from = removed.map(\.norm).joined(separator: " ")
            let to = added.map(\.clean).joined(separator: " ")
            guard !from.isEmpty, !to.isEmpty, from != to else { continue }
            // Only learn from edits to words we actually inserted, so typing
            // elsewhere in the document never produces a bogus rule.
            guard insertedNorm.contains(" \(from) ") else { continue }
            pairs.append((from, to))
        }
        return pairs
    }

    struct Token {
        let raw: String
        let norm: String   // lowercased, surrounding punctuation stripped
        let clean: String  // original case, surrounding punctuation stripped
    }

    static func tokenize(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).compactMap { word in
            let clean = String(word).trimmingCharacters(
                in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            guard !clean.isEmpty else { return nil }
            return Token(raw: String(word), norm: clean.lowercased(), clean: clean)
        }
    }

    // LCS alignment; consecutive (delete+insert) regions between anchors become
    // substitution runs.
    private static func substitutionRuns(
        _ a: [Token], _ b: [Token]
    ) -> [(removed: [Token], added: [Token])] {
        let n = a.count, m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i].norm == b[j].norm
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var runs: [(removed: [Token], added: [Token])] = []
        var removed: [Token] = []
        var added: [Token] = []
        var i = 0, j = 0
        func flush() {
            if !removed.isEmpty || !added.isEmpty {
                runs.append((removed, added))
                removed = []
                added = []
            }
        }
        while i < n, j < m {
            if a[i].norm == b[j].norm {
                // Same word, different casing counts as part of the correction
                // ("cloud code" -> "Claude Code" must stay one phrase-level pair);
                // identical tokens are anchors that close the current run.
                if a[i].clean != b[j].clean {
                    removed.append(a[i])
                    added.append(b[j])
                } else {
                    flush()
                }
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                removed.append(a[i])
                i += 1
            } else {
                added.append(b[j])
                j += 1
            }
        }
        removed.append(contentsOf: a[i...])
        added.append(contentsOf: b[j...])
        flush()
        return runs
    }
}

public struct CorrectionRule: Codable, Equatable {
    public let from: String
    public var to: String
    public var count: Int

    public init(from: String, to: String, count: Int) {
        self.from = from
        self.to = to
        self.count = count
    }
}

// Persistent, local-only memory of the user's corrections. Rules seen at least
// `promotionThreshold` times are applied deterministically to future transcripts,
// and learned terms feed the whisper vocabulary hint.
public final class LearningStore {
    public static let promotionThreshold = 2
    private static let maxRules = 200

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.cadenwarren.freespeech.learning")
    private var rules: [CorrectionRule] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([CorrectionRule].self, from: data) {
            rules = loaded
        }
    }

    public var ruleCount: Int { queue.sync { rules.count } }
    public var promotedCount: Int {
        queue.sync { rules.filter { $0.count >= Self.promotionThreshold }.count }
    }

    public func recordCorrections(_ pairs: [(from: String, to: String)]) {
        guard !pairs.isEmpty else { return }
        queue.sync {
            for (from, to) in pairs {
                if let idx = rules.firstIndex(where: { $0.from == from }) {
                    rules[idx].count += 1
                    rules[idx].to = to  // latest correction wins
                } else {
                    rules.append(CorrectionRule(from: from, to: to, count: 1))
                }
            }
            if rules.count > Self.maxRules {
                rules.sort { $0.count > $1.count }
                rules.removeLast(rules.count - Self.maxRules)
            }
            persist()
        }
    }

    public func apply(to text: String) -> String {
        let promoted = queue.sync { rules.filter { $0.count >= Self.promotionThreshold } }
        return TextReplacements.apply(rules: promoted.map { ($0.from, $0.to) }, to: text)
    }

    // Most-corrected target phrases, for biasing whisper toward words the user wants.
    public func vocabularyTerms(limit: Int = 12) -> [String] {
        queue.sync {
            rules.filter { $0.count >= Self.promotionThreshold }
                .sorted { $0.count > $1.count }
                .prefix(limit)
                .map(\.to)
        }
    }

    public func reset() {
        queue.sync {
            rules = []
            persist()
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(rules)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("learning store persist failed at \(fileURL.path): \(error)")
        }
    }
}
