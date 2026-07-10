import AVFoundation
import FreeSpeechCore

// Headless mode for mechanical verification: model-load and transcription timing
// against a known audio file, no GUI, no permissions needed.
enum TranscribeFileCommand {
    static func run(arguments: [String]) -> Int32 {
        guard let flagIndex = arguments.firstIndex(of: "--transcribe-file"),
              arguments.count > flagIndex + 1 else {
            FileHandle.standardError.write(Data("usage: FreeSpeech --transcribe-file <audio> [--model <name>]\n".utf8))
            return 2
        }
        let path = arguments[flagIndex + 1]
        var modelName = Settings().modelName
        var beamSize = 1
        var runs = 1
        if let i = arguments.firstIndex(of: "--model"), arguments.count > i + 1 {
            modelName = arguments[i + 1]
        }
        if let i = arguments.firstIndex(of: "--beam-size"), arguments.count > i + 1 {
            beamSize = Int(arguments[i + 1]) ?? 1
        }
        if let i = arguments.firstIndex(of: "--runs"), arguments.count > i + 1 {
            runs = max(1, Int(arguments[i + 1]) ?? 1)
        }
        var vocabularyHint: String?
        if let i = arguments.firstIndex(of: "--prompt"), arguments.count > i + 1 {
            vocabularyHint = arguments[i + 1]
        }
        var language = "en"
        if let i = arguments.firstIndex(of: "--language"), arguments.count > i + 1 {
            language = arguments[i + 1]
        }
        let splitSpeakers = arguments.contains("--split-speakers")

        do {
            let samples = try loadSamples(path: path)
            let engine = WhisperCppEngine()

            let loadStart = CFAbsoluteTimeGetCurrent()
            try engine.loadModel(at: AppPaths.modelFile(named: modelName))
            let loadTime = CFAbsoluteTimeGetCurrent() - loadStart

            // Multiple runs: first includes Metal warmup; report the best (steady-state).
            var best = Double.greatestFiniteMagnitude
            var raw = ""
            for _ in 0..<runs {
                let start = CFAbsoluteTimeGetCurrent()
                raw = try engine.transcribe(
                    samples: samples, timeout: 120, beamSize: beamSize,
                    vocabularyHint: vocabularyHint, language: language)
                best = min(best, CFAbsoluteTimeGetCurrent() - start)
            }

            var cleaned = TranscriptCleaner.clean(raw) ?? ""
            if splitSpeakers {
                let segments = try engine.transcribeSegments(
                    samples: samples, timeout: 120, beamSize: beamSize,
                    vocabularyHint: vocabularyHint, language: language,
                    detectSpeakerTurns: false)
                let diarizer = WhisperCppEngine()
                let turnStart = CFAbsoluteTimeGetCurrent()
                try diarizer.loadModel(
                    at: AppPaths.modelFile(named: Settings.diarizerModelName))
                let turnSegments = try diarizer.transcribeSegments(
                    samples: samples, timeout: 120, beamSize: 1,
                    vocabularyHint: nil, language: "en", detectSpeakerTurns: true)
                let turns = turnSegments.filter(\.speakerTurnNext).map(\.end)
                print(String(format: "diarize_pass_s: %.3f", CFAbsoluteTimeGetCurrent() - turnStart))
                for s in turnSegments {
                    print(String(format: "tdrz_segment: %.2f-%.2f turn=%@ %@",
                                 s.start, s.end, s.speakerTurnNext ? "YES" : "no", s.text))
                }
                print("turns: \(turns.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
                cleaned = TranscriptCleaner.cleanPreservingLines(SpeakerSplitter.merged(
                    segments: segments.map { TimedSegment(start: $0.start, text: $0.text) },
                    turnTimes: turns)) ?? ""
            }
            print("model: \(modelName)")
            print("beam_size: \(beamSize)")
            print(String(format: "model_load_s: %.3f", loadTime))
            print(String(format: "audio_s: %.1f", Double(samples.count) / Double(WhisperCppEngine.sampleRate)))
            print(String(format: "transcribe_s: %.3f", best))
            print("transcript: \(cleaned)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func loadSamples(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioRecorderError.converterInitFailed
        }
        try file.read(into: buffer)

        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperCppEngine.sampleRate),
            channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw AudioRecorderError.converterInitFailed
        }
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioRecorderError.converterInitFailed
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw error ?? AudioRecorderError.converterInitFailed
        }
        guard let channel = out.floatChannelData?[0] else {
            throw AudioRecorderError.converterInitFailed
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
