import Foundation

public struct TimedSegment: Equatable {
    public let start: Double
    public let end: Double?
    public let text: String

    public init(start: Double, end: Double? = nil, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

// Two-pass speaker splitting: the accurate model produces the words, a
// separate tinydiarize pass produces only the times where the voice changed.
// Splitting works at word level — whisper's segments can span 10+ seconds and
// a turn inside one would otherwise be lost.
public enum SpeakerSplitter {
    // Absorbs timestamp drift between two independent whisper runs. Kept tight:
    // too loose and the break lands a word early on the previous speaker.
    public static let defaultTolerance = 0.25

    // `pieces` are whisper token texts in order (a leading space marks a word
    // boundary; pieces concatenate verbatim). A turn breaks the line at the
    // next word boundary, so a turn mid-word can never split the word.
    public static func merged(
        pieces: [TimedSegment], turnTimes: [Double],
        tolerance: Double = defaultTolerance
    ) -> String {
        let turns = turnTimes.sorted()
        var turnIndex = 0
        var pendingTurn = false
        var out = ""
        for piece in pieces {
            let pieceEnd = max(piece.end ?? piece.start, piece.start)
            let midpoint = piece.start + (pieceEnd - piece.start) / 2
            let startsWord = piece.text.hasPrefix(" ")

            // A diarizer timestamp just after a word starts may be clock drift.
            // Only move that whole word to the new speaker when the turn is in
            // its first half; turns in the second half belong after the word.
            if startsWord {
                while turnIndex < turns.count {
                    let turn = turns[turnIndex]
                    let beforePiece = turn <= piece.start
                    let nearPieceStart = turn <= piece.start + tolerance && turn <= midpoint
                    guard beforePiece || nearPieceStart else { break }
                    pendingTurn = true
                    turnIndex += 1
                }
            }

            if out.isEmpty {
                pendingTurn = false
                out = String(piece.text.drop { $0 == " " })
            } else if pendingTurn, startsWord {
                pendingTurn = false
                out += "\n" + String(piece.text.dropFirst())
            } else {
                out += piece.text
            }

            // A turn inside (or immediately after) this token is applied at the
            // next word boundary so the current word stays with its speaker.
            while turnIndex < turns.count, turns[turnIndex] <= pieceEnd + tolerance {
                pendingTurn = true
                turnIndex += 1
            }
        }
        return capitalizeLineStarts(out)
    }

    // Each line is a fresh utterance, so sentence casing is safe here.
    private static func capitalizeLineStarts(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            guard let first = line.first, first.isLowercase else { return line }
            return first.uppercased() + line.dropFirst()
        }.joined(separator: "\n")
    }
}
