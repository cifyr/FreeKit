import AVFoundation
import FreeSpeechCore

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case deviceInputFailed(String, Error)
    case sessionRejectedDevice(String)
    case engineStartFailed(Error)
    case converterInitFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device available"
        case .deviceInputFailed(let name, let err):
            return "Cannot open microphone \"\(name)\": \(err.localizedDescription)"
        case .sessionRejectedDevice(let name):
            return "Capture session rejected microphone \"\(name)\""
        case .engineStartFailed(let err):
            return "Audio engine failed to start: \(err.localizedDescription)"
        case .converterInitFailed:
            return "Could not create 16 kHz mono audio converter"
        }
    }
}

// Microphone capture via AVCaptureSession: device selection is first-class
// (AVAudioEngine's device binding negotiated stale formats on Bluetooth mics,
// error -10868 / starved taps) and buffers arrive as CMSampleBuffers that the
// shared accumulator resamples to 16 kHz mono.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onLevel: ((Float) -> Void)? {
        get { accumulator.onLevel }
        set { accumulator.onLevel = newValue }
    }
    var onMaxDuration: (() -> Void)?

    private let accumulator = PCMSampleAccumulator()
    private var session: AVCaptureSession?
    private var maxDurationTimer: DispatchWorkItem?
    private let sampleQueue = DispatchQueue(label: "com.cadenwarren.freespeech.micsamples")
    private(set) var isRecording = false

    func start(maxSeconds: Double, device preferred: AudioInputDevice? = nil) throws {
        precondition(!isRecording, "start called while already recording")

        var device: AVCaptureDevice?
        if let preferred {
            // AVCaptureDevice uniqueIDs are the CoreAudio device UIDs we store.
            device = AVCaptureDevice(uniqueID: preferred.uid)
            if device == nil {
                Log.error("preferred mic \"\(preferred.name)\" [\(preferred.uid)] not visible to AVCapture, falling back to default input")
            } else {
                Log.info("recording using preferred mic: \(preferred.name) [\(preferred.uid)]")
            }
        }
        guard let resolved = device ?? AVCaptureDevice.default(for: .audio) else {
            throw AudioRecorderError.noInputDevice
        }
        Log.info("recording start: device \"\(resolved.localizedName)\", max \(Int(maxSeconds))s")

        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: resolved)
        } catch {
            throw AudioRecorderError.deviceInputFailed(resolved.localizedName, error)
        }
        guard session.canAddInput(input) else {
            throw AudioRecorderError.sessionRejectedDevice(resolved.localizedName)
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Ask for whisper's format up front; the accumulator still converts if
        // the session delivers something else.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        guard session.canAddOutput(output) else {
            throw AudioRecorderError.sessionRejectedDevice(resolved.localizedName)
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        accumulator.reset()
        self.session = session
        isRecording = true

        // startRunning blocks while the device spins up (Bluetooth can take a
        // few hundred ms); off the main thread so the HUD appears instantly.
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            Log.info("capture session running: \(session.isRunning)")
        }

        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            Log.info("recording hit max duration (\(Int(maxSeconds))s), auto-stopping")
            self.onMaxDuration?()
        }
        maxDurationTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds, execute: timer)
    }

    // Returns all captured samples; always leaves the mic released.
    @discardableResult
    func stop() -> [Float] {
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
        guard isRecording else { return [] }
        isRecording = false
        if let session {
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
            }
        }
        session = nil
        let result = accumulator.drain()
        Log.info("recording stop: \(result.count) samples (\(String(format: "%.1f", Double(result.count) / Double(WhisperCppEngine.sampleRate)))s)")
        if result.isEmpty {
            Log.error("recording produced zero samples — capture session delivered no buffers")
        }
        return result
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording else { return }
        accumulator.ingest(sampleBuffer)
    }
}
