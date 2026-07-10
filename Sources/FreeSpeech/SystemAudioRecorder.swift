import AVFoundation
import ScreenCaptureKit
import FreeSpeechCore

enum SystemAudioError: LocalizedError {
    case permissionDenied
    case noDisplay
    case captureStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording not granted — enable FreeSpeech in System Settings > Privacy & Security > Screen Recording"
        case .noDisplay:
            return "No display available for system audio capture"
        case .captureStartFailed(let err):
            return "System audio capture failed to start: \(err.localizedDescription)"
        }
    }
}

// Captures computer output audio (the other side of a call, a video, anything the
// Mac plays) via ScreenCaptureKit's audio tap — no virtual audio driver needed.
// Mirrors AudioRecorder's contract: accumulate 16 kHz mono floats, RMS levels out.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var onLevel: ((Float) -> Void)? {
        get { accumulator.onLevel }
        set { accumulator.onLevel = newValue }
    }
    var onMaxDuration: (() -> Void)?

    private let accumulator = PCMSampleAccumulator()
    private var stream: SCStream?
    private var maxDurationTimer: DispatchWorkItem?
    private let sampleQueue = DispatchQueue(label: "com.cadenwarren.freespeech.sysaudio")
    private(set) var isRecording = false

    // SCStream setup is async (shareable-content lookup); the completion fires on
    // the main queue. On any failure the recorder is left fully stopped.
    func start(maxSeconds: Double, completion: @escaping (Error?) -> Void) {
        precondition(!isRecording, "start called while already recording")
        accumulator.reset()
        isRecording = true
        Log.info("system audio capture starting, max \(Int(maxSeconds))s")

        Task { @MainActor in
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else {
                    throw SystemAudioError.noDisplay
                }
                guard self.isRecording else { return }  // released before setup finished

                let filter = SCContentFilter(
                    display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                // Video is mandatory for SCStream; keep it as cheap as possible
                // since only the audio output is attached.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
                try await stream.startCapture()
                guard self.isRecording else {
                    // Hotkey already released during setup: shut the capture down.
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                Log.info("system audio capture running")

                let timer = DispatchWorkItem { [weak self] in
                    guard let self, self.isRecording else { return }
                    Log.info("system audio capture hit max duration (\(Int(maxSeconds))s), auto-stopping")
                    self.onMaxDuration?()
                }
                self.maxDurationTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds, execute: timer)
                completion(nil)
            } catch {
                Log.error("system audio capture setup failed: \(error.localizedDescription)")
                self.isRecording = false
                self.stream = nil
                completion(SystemAudioError.captureStartFailed(error))
            }
        }
    }

    // Returns all captured samples; always leaves the capture stopped.
    @discardableResult
    func stop() -> [Float] {
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
        guard isRecording else { return [] }
        isRecording = false
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        let result = accumulator.drain()
        Log.info("system audio capture stop: \(result.count) samples (\(String(format: "%.1f", Double(result.count) / Double(WhisperCppEngine.sampleRate)))s)")
        return result
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, isRecording else { return }
        accumulator.ingest(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("system audio stream stopped by system: \(error.localizedDescription)")
        _ = stop()
    }
}
