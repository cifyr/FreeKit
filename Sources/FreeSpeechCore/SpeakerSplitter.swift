import Foundation

public struct TimedSegment: Equatable {
    public let start: Double
    public let text: String

    public init(start: Double, text: String) {
        self.start = start
        self.text = text
    }
}

// Two-pass speaker splitting: the accurate model produces the segments, a
// separate tinydiarize pass produces only the times where the voice changed.
// Merging inserts a line break at each segment boundary following a turn.
public enum SpeakerSplitter {
    // Absorbs timestamp drift between two independent whisper runs; turns snap
    // to segment boundaries so text is never split mid-word.
    public static let defaultTolerance = 0.4

    public static func merged(
        segments: [TimedSegment], turnTimes: [Double],
        tolerance: Double = defaultTolerance
    ) -> String {
        let turns = turnTimes.sorted()
        var turnIndex = 0
        var out = ""
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var turnBeforeSegment = false
            while turnIndex < turns.count, turns[turnIndex] <= segment.start + tolerance {
                turnBeforeSegment = true
                turnIndex += 1
            }
            if out.isEmpty {
                out = text
            } else {
                out += (turnBeforeSegment ? "\n" : " ") + text
            }
        }
        return out
    }
}
