import Foundation

// Deterministic cleanup only — no LLM, no reflow. Returns nil when there is no real speech.
public enum TranscriptCleaner {
    // Non-speech markers whisper emits for silence/noise, e.g. [BLANK_AUDIO], (wind blowing).
    private static let markerPattern = try! NSRegularExpression(
        pattern: #"\[[^\]]*\]|\([^)]*\)|♪+"#)

    public static func clean(_ raw: String) -> String? {
        let ns = raw as NSString
        var text = markerPattern.stringByReplacingMatches(
            in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        text = text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // First-letter casing is decided at insert time by SmartInsertion, which
        // knows the caret context; capitalizing here would fight continuations.
        return text
    }

    // For speaker-split transcripts: line breaks are the speaker turns and must
    // survive cleanup, so each line is cleaned independently.
    public static func cleanPreservingLines(_ raw: String) -> String? {
        let lines = raw.components(separatedBy: "\n").compactMap { clean($0) }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
