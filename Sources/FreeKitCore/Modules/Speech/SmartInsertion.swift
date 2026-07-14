import Foundation

// Deterministic insert-time shaping: overlap dedup ("continue, don't duplicate"),
// sentence-continuation casing, and leading spacing. This is the single authority
// for first-letter casing; TranscriptCleaner deliberately no longer capitalizes.
public enum SmartInsertion {
    // Exact-token, case-insensitive matching over a short window: fuzzier matching
    // risks merging phrases the user genuinely repeated.
    public static let maxOverlapWords = 8

    // Full pipeline. `textBeforeCaret` nil means the field was unreadable over AX:
    // fail closed to a plain insert (capitalized, untouched spacing).
    public static func prepare(transcript: String, textBeforeCaret: String?) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let before = textBeforeCaret else {
            return capitalizeFirst(trimmed)
        }
        let deduped = overlapTrimmed(transcript: trimmed, textBeforeCaret: before)
        guard !deduped.isEmpty else { return "" }
        return applyCasingAndSpacing(deduped, textBeforeCaret: before)
    }

    // Drops the longest run of leading transcript words that already sit at the
    // end of the text before the caret, e.g. "let's meet at" + "let's meet at
    // three" inserts only "three".
    public static func overlapTrimmed(transcript: String, textBeforeCaret: String) -> String {
        let headWords = words(in: transcript)
        let tailWords = Array(words(in: textBeforeCaret).suffix(maxOverlapWords))
        guard !headWords.isEmpty, !tailWords.isEmpty else { return transcript }

        let maxLen = min(headWords.count, tailWords.count)
        var overlap = 0
        for k in stride(from: maxLen, through: 1, by: -1) {
            if tailWords.suffix(k).map(normalize) == headWords.prefix(k).map(normalize) {
                overlap = k
                break
            }
        }
        guard overlap > 0 else { return transcript }

        // Cut after the overlap-th word of the raw transcript, preserving the
        // original spacing/punctuation of what remains.
        var remaining = Substring(transcript)
        for _ in 0..<overlap {
            remaining = remaining.drop { $0.isWhitespace }
            remaining = remaining.drop { !$0.isWhitespace }
        }
        return String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // New sentence (empty field or after ./!/?/newline) capitalizes; a mid-sentence
    // continuation stays lowercase and gets exactly one leading space.
    public static func applyCasingAndSpacing(_ transcript: String, textBeforeCaret: String) -> String {
        guard let context = lastNonSpaceCharacter(in: textBeforeCaret) else {
            // Empty field (or only whitespace): fresh sentence, no leading space.
            return capitalizeFirst(transcript)
        }
        let endsWithWhitespace = textBeforeCaret.last?.isWhitespace ?? false
        if isSentenceTerminator(context) || textBeforeCaret.hasSuffix("\n") {
            let text = capitalizeFirst(transcript)
            return endsWithWhitespace ? text : " " + text
        }
        let text = lowercaseFirst(transcript)
        return endsWithWhitespace ? text : " " + text
    }

    private static func isSentenceTerminator(_ ch: Character) -> Bool {
        ch == "." || ch == "!" || ch == "?" || ch == "\n"
    }

    private static func lastNonSpaceCharacter(in text: String) -> Character? {
        // Newlines count as context (they force a fresh sentence), spaces do not.
        text.last { !($0 == " " || $0 == "\t") }
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(
            in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
    }

    private static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func lowercaseFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        // Words whisper capitalizes mid-sentence on purpose (I, proper nouns) are
        // indistinguishable from sentence-start casing for the first word only when
        // it is a bare "I" form; keep those.
        let firstWord = text.prefix { !$0.isWhitespace }
        if firstWord == "I" || firstWord.hasPrefix("I'") {
            return text
        }
        return first.lowercased() + text.dropFirst()
    }
}
