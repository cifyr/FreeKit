import Foundation
import CWhisper
import FreeSpeechCore

enum TranscriptionError: LocalizedError {
    case modelNotFound(URL)
    case modelLoadFailed(URL)
    case notLoaded
    case whisperFailed(Int32)
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let url):
            return "Model file not found at \(url.path) — run ./build.sh to fetch it"
        case .modelLoadFailed(let url):
            return "Failed to load model \(url.lastPathComponent)"
        case .notLoaded:
            return "Transcription engine has no model loaded"
        case .whisperFailed(let code):
            return "whisper_full failed with code \(code)"
        case .timedOut(let seconds):
            return "Transcription timed out after \(Int(seconds))s"
        }
    }
}

struct EngineSegment {
    let start: Double
    let end: Double
    let text: String
    // Only meaningful when the loaded model supports tinydiarize (small.en-tdrz).
    let speakerTurnNext: Bool
}

// Small interface so the engine can be swapped without touching capture/insert code.
protocol TranscriptionEngine: AnyObject {
    var isLoaded: Bool { get }
    func loadModel(at url: URL) throws
    func transcribe(samples: [Float], timeout: TimeInterval, beamSize: Int, vocabularyHint: String?, language: String) throws -> String
    func transcribeSegments(samples: [Float], timeout: TimeInterval, beamSize: Int, vocabularyHint: String?, language: String, detectSpeakerTurns: Bool) throws -> [EngineSegment]
}

private final class AbortBox {
    var deadline: CFAbsoluteTime = .greatestFiniteMagnitude
}

final class WhisperCppEngine: TranscriptionEngine {
    static let sampleRate = 16_000

    private var ctx: OpaquePointer?
    private let abortBox = AbortBox()

    var isLoaded: Bool { ctx != nil }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    func loadModel(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.modelNotFound(url)
        }
        if let old = ctx {
            whisper_free(old)
            ctx = nil
        }
        let started = CFAbsoluteTimeGetCurrent()
        Log.info("model load start: \(url.path)")
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let newCtx = whisper_init_from_file_with_params(url.path, cparams) else {
            throw TranscriptionError.modelLoadFailed(url)
        }
        ctx = newCtx
        Log.info(String(format: "model load done in %.2fs", CFAbsoluteTimeGetCurrent() - started))
    }

    func transcribe(samples: [Float], timeout: TimeInterval, beamSize: Int, vocabularyHint: String?, language: String) throws -> String {
        try transcribeSegments(
            samples: samples, timeout: timeout, beamSize: beamSize,
            vocabularyHint: vocabularyHint, language: language, detectSpeakerTurns: false)
            .map(\.text).joined()
    }

    func transcribeSegments(samples: [Float], timeout: TimeInterval, beamSize: Int, vocabularyHint: String?, language: String, detectSpeakerTurns: Bool) throws -> [EngineSegment] {
        guard let ctx else { throw TranscriptionError.notLoaded }

        // whisper.cpp requires at least ~1s of audio; pad short clips with silence.
        var input = samples
        let minSamples = Int(1.1 * Double(Self.sampleRate))
        if input.count < minSamples {
            input.append(contentsOf: [Float](repeating: 0, count: minSamples - input.count))
        }

        var params = whisper_full_default_params(
            beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        if beamSize > 1 {
            params.beam_search.beam_size = Int32(beamSize)
        }
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.translate = false
        params.no_context = true
        params.suppress_blank = true
        params.tdrz_enable = detectSpeakerTurns
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount)))

        // Vocabulary bias: whisper conditions its decoder on this as if it preceded
        // the audio, steering proper nouns (names, product terms) the right way.
        let cHint: UnsafeMutablePointer<CChar>? =
            (vocabularyHint?.isEmpty == false) ? strdup(vocabularyHint!) : nil
        defer { if let cHint { free(cHint) } }
        if let cHint { params.initial_prompt = UnsafePointer(cHint) }

        abortBox.deadline = CFAbsoluteTimeGetCurrent() + timeout
        params.abort_callback = { userData in
            guard let userData else { return false }
            let box = Unmanaged<AbortBox>.fromOpaque(userData).takeUnretainedValue()
            return CFAbsoluteTimeGetCurrent() > box.deadline
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abortBox).toOpaque()

        let started = CFAbsoluteTimeGetCurrent()
        Log.info("transcription start: \(input.count) samples (\(String(format: "%.1f", Double(input.count) / Double(Self.sampleRate)))s), beam \(beamSize), language \(language), hint \(vocabularyHint.map { "\"\($0)\"" } ?? "none")")

        // whisper.cpp treats "auto" as detect-from-audio; .en models ignore it.
        let status: Int32 = language.withCString { lang in
            params.language = lang
            return input.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        if status != 0 {
            if CFAbsoluteTimeGetCurrent() > abortBox.deadline {
                throw TranscriptionError.timedOut(timeout)
            }
            throw TranscriptionError.whisperFailed(status)
        }

        var segments: [EngineSegment] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            guard let seg = whisper_full_get_segment_text(ctx, i) else { continue }
            // Segment timestamps are in centiseconds.
            segments.append(EngineSegment(
                start: Double(whisper_full_get_segment_t0(ctx, i)) / 100.0,
                end: Double(whisper_full_get_segment_t1(ctx, i)) / 100.0,
                text: String(cString: seg),
                speakerTurnNext: detectSpeakerTurns
                    && whisper_full_get_segment_speaker_turn_next(ctx, i)))
        }
        Log.info(String(format: "transcription done in %.2fs (%d segments): \"%@\"",
                        elapsed, segments.count, segments.map(\.text).joined()))
        return segments
    }
}
