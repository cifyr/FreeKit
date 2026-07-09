import AVFoundation
import FreeSpeechCore

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case engineStartFailed(Error)
    case converterInitFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device available"
        case .engineStartFailed(let err):
            return "Audio engine failed to start: \(err.localizedDescription)"
        case .converterInitFailed:
            return "Could not create 16 kHz mono audio converter"
        }
    }
}

// Captures the default input device and accumulates 16 kHz mono Float32 samples.
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?
    var onMaxDuration: (() -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private var maxDurationTimer: DispatchWorkItem?
    private(set) var isRecording = false

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(WhisperCppEngine.sampleRate),
        channels: 1, interleaved: false)!

    func start(maxSeconds: Double, device: AudioInputDevice? = nil) throws {
        precondition(!isRecording, "start called while already recording")

        // Fresh engine per session: survives default-device changes between dictations.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device {
            // Bind the user's preferred mic instead of the system default input.
            var deviceID = device.deviceID
            let status = AudioUnitSetProperty(
                input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                Log.error("could not bind preferred mic \"\(device.name)\" (status \(status)), falling back to system default")
            } else {
                Log.info("recording using preferred mic: \(device.name) [\(device.uid)]")
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        Log.info("recording start: input format \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch, max \(Int(maxSeconds))s")
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw AudioRecorderError.converterInitFailed
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engineStartFailed(error)
        }
        self.engine = engine
        isRecording = true

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
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        lock.lock()
        let result = samples
        samples.removeAll()
        lock.unlock()
        Log.info("recording stop: \(result.count) samples (\(String(format: "%.1f", Double(result.count) / Double(WhisperCppEngine.sampleRate)))s)")
        return result
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            onLevel?(rms)
        }

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.error("audio conversion failed: \(error?.localizedDescription ?? "unknown")")
            return
        }
        guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        lock.unlock()
    }
}
