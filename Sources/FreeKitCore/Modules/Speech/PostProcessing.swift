import Foundation

public enum PostProcessingMode: String, CaseIterable {
    case off
    case cleanup
    case grammar
    case structure
    case tone

    public var displayName: String {
        switch self {
        case .off: return "Do nothing"
        case .cleanup: return "Basic cleanup"
        case .grammar: return "Fix grammar"
        case .structure: return "Fix sentence structure"
        case .tone: return "Rewrite in a tone"
        }
    }

    public var detail: String {
        switch self {
        case .off: return "Raw whisper output, untouched"
        case .cleanup: return "Trim, capitalize, strip noise markers (deterministic)"
        case .grammar: return "Cleanup plus on-device grammar and punctuation fixes"
        case .structure: return "Cleanup plus on-device sentence restructuring for clarity"
        case .tone: return "Cleanup plus on-device rewrite in your chosen tone"
        }
    }

    // Modes above cleanup need the on-device Apple language model.
    public var needsLanguageModel: Bool {
        switch self {
        case .off, .cleanup: return false
        case .grammar, .structure, .tone: return true
        }
    }
}

public enum RewriteTone: String, CaseIterable {
    case professional
    case friendly
    case casual
    case concise

    public var displayName: String { rawValue.capitalized }
}
