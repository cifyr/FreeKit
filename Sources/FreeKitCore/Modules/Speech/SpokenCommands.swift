import Foundation

// Deterministic spoken-command handling: a small, conservative phrase set so
// normal speech ("the new line of products") is never mangled — commands only
// match as standalone phrases, optionally wrapped in whisper's punctuation.
public enum SpokenCommands {
    // "scratch that" discards everything said up to and including the phrase.
    public static func apply(to text: String) -> String {
        var result = scratchThat(in: text)
        result = replacePhrase("new paragraph", in: result, with: "\n\n")
        result = replacePhrase("new line", in: result, with: "\n")
        result = replacePhrase("newline", in: result, with: "\n")
        result = capitalizeAfterNewlines(result)
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    private static func scratchThat(in text: String) -> String {
        let pattern = #"(?i)^.*\bscratch that\b[.,!?]?\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    // Consumes the punctuation whisper glues onto the phrase ("New line.") and a
    // dangling comma before it ("thanks, new line"), but never a sentence-ending
    // period, which belongs to the preceding text.
    private static func replacePhrase(_ phrase: String, in text: String, with replacement: String) -> String {
        let pattern = #"(?i)[ \t]*[,;]?\s*\b"# + NSRegularExpression.escapedPattern(for: phrase)
            + #"\b[.,!?]?[ \t]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    private static func capitalizeAfterNewlines(_ text: String) -> String {
        var chars = Array(text)
        for i in 1..<max(1, chars.count) {
            if chars[i - 1] == "\n", chars[i].isLowercase {
                chars[i] = Character(chars[i].uppercased())
            }
        }
        return String(chars)
    }
}

// Filler removal is separate from commands so each has its own toggle.
public enum FillerWords {
    // Trailing whitespace match excludes newlines: those are speaker turns in
    // split transcripts and must survive a filler sitting at the end of a line.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?i)\b(um+|uh+|uhm+|erm+|mm-?hmm?)\b[,.]?[ \t]*"#)

    public static func strip(_ text: String) -> String {
        let stripped = pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return stripped
            .replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// Shared word-boundary replacement used by both the learned rules and the
// user's manual dictionary.
public enum TextReplacements {
    public static func apply(rules: [(from: String, to: String)], to text: String) -> String {
        var result = text
        for rule in rules where !rule.from.isEmpty {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: rule.from))\\b"
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.to))
        }
        return result
    }
}
