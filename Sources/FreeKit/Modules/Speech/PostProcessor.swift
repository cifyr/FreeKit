import Foundation
import FoundationModels
import FreeKitCore

// LLM post-processing via Apple's on-device foundation model: nothing leaves the
// machine. Any failure (model unavailable, timeout, refusal) falls back to the
// deterministic-cleaned text so dictation never breaks because of the rewriter.
final class PostProcessor {
    private static let rewriteTimeout: TimeInterval = 15

    var languageModelAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func process(_ text: String, mode: PostProcessingMode, tone: RewriteTone) -> String {
        guard mode.needsLanguageModel else { return text }
        guard languageModelAvailable else {
            Log.error("post-processing \(mode.rawValue) requested but Apple Intelligence model unavailable, using cleaned text")
            return text
        }
        let instructions: String
        switch mode {
        case .grammar:
            instructions = "You correct dictated text. Fix grammar, punctuation, and capitalization only. Do not change the wording, meaning, or order of ideas. Reply with only the corrected text."
        case .structure:
            instructions = "You edit dictated text. Fix grammar and restructure awkward sentences so they read clearly, while fully preserving the meaning and the speaker's voice. Reply with only the edited text."
        case .tone:
            instructions = "You rewrite dictated text in a \(tone.rawValue) tone, preserving the meaning and approximate length. Reply with only the rewritten text."
        case .off, .cleanup:
            return text
        }

        let started = CFAbsoluteTimeGetCurrent()
        Log.info("post-processing start: mode \(mode.rawValue), \(text.count) chars")
        guard let rewritten = respond(instructions: instructions, prompt: text) else {
            return text
        }
        let cleaned = stripWrapping(rewritten)
        Log.info(String(format: "post-processing done in %.2fs: \"%@\"", CFAbsoluteTimeGetCurrent() - started, cleaned))
        return cleaned.isEmpty ? text : cleaned
    }

    // Bridges the async FoundationModels call for the GCD transcription pipeline.
    // Must not be called on the main thread.
    private func respond(instructions: String, prompt: String) -> String? {
        precondition(!Thread.isMainThread, "PostProcessor.respond would deadlock on main")
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        Task {
            defer { semaphore.signal() }
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt)
                result = response.content
            } catch {
                Log.error("language model rewrite failed: \(error.localizedDescription)")
            }
        }
        if semaphore.wait(timeout: .now() + Self.rewriteTimeout) == .timedOut {
            Log.error("language model rewrite timed out after \(Int(Self.rewriteTimeout))s")
            return nil
        }
        return result
    }

    private func stripWrapping(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count > 1 {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
