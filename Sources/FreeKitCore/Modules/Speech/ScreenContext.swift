import Foundation

// Mines likely proper nouns (names, products, places) from text visible on
// screen so whisper can be biased toward them: replying to Gurkaran should make
// "Gurkaran" transcribe correctly. Deterministic, local, capped.
public enum ScreenContext {
    // Common capitalized words that are structure, not vocabulary.
    private static let stoplist: Set<String> = [
        "i", "a", "an", "the", "this", "that", "these", "those", "it", "its",
        "we", "you", "he", "she", "they", "my", "your", "our", "his", "her",
        "hi", "hello", "hey", "dear", "thanks", "thank", "regards", "best",
        "sincerely", "cheers", "ok", "okay", "yes", "no", "and", "or", "but",
        "if", "so", "as", "on", "in", "at", "for", "to", "from", "of", "with",
        "re", "fwd", "fw", "subject", "date", "sent", "cc", "bcc", "reply",
        "inbox", "draft", "new", "message", "email", "mail", "untitled",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    public static func properNouns(in text: String, limit: Int = 10) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []

        func record(_ term: String) {
            let key = term.lowercased()
            guard !stoplist.contains(key) else { return }
            if counts[key] == nil { order.append(term) }
            counts[key, default: 0] += 1
        }

        var sentenceStart = true
        var run: [String] = []
        var runStartedSentence = false

        func flushRun() {
            defer { run = [] }
            guard !run.isEmpty else { return }
            // A lone capitalized word at a sentence start is just normal casing;
            // multi-word runs (names) count even there.
            if runStartedSentence && run.count == 1 { return }
            record(run.joined(separator: " "))
        }

        for rawToken in text.split(whereSeparator: \.isWhitespace) {
            let token = String(rawToken)
            let cleaned = token.trimmingCharacters(
                in: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted)

            if let at = token.firstIndex(of: "@"), at != token.startIndex {
                // Email local part is usually the person's name.
                let local = token[token.startIndex..<at].trimmingCharacters(
                    in: CharacterSet.alphanumerics.inverted)
                if local.count >= 3, local.rangeOfCharacter(from: .decimalDigits) == nil {
                    record(local.capitalized)
                }
            }

            let isCapitalizedWord = cleaned.count >= 2
                && cleaned.first!.isUppercase
                && cleaned.dropFirst().allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }

            // Stoplisted words break runs rather than being filtered afterwards,
            // otherwise "On Tuesday, Gurkaran" would glue into one bogus term and
            // a name after "Thanks," would inherit sentence-start status.
            if isCapitalizedWord, !stoplist.contains(cleaned.lowercased()) {
                if run.isEmpty { runStartedSentence = sentenceStart }
                if run.count < 3 { run.append(cleaned) }
            } else {
                flushRun()
            }

            sentenceStart = token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?")
                || token.hasSuffix(":") || token.hasSuffix("\n") || cleaned.isEmpty
        }
        flushRun()

        return order
            .sorted { (counts[$0.lowercased()] ?? 0) > (counts[$1.lowercased()] ?? 0) }
            .prefix(limit)
            .map { $0 }
    }
}
