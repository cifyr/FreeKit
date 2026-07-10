import AVFoundation
import FreeSpeechCore

// Shared by the mic and system-audio recorders: turns whatever CMSampleBuffers
// a capture source delivers into accumulated 16 kHz mono Float32 samples, with
// RMS levels out. The converter is built lazily from the first buffer's actual
// format — the only description guaranteed to match delivery.
final class PCMSampleAccumulator {
    var onLevel: ((Float) -> Void)?

    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private var loggedFormat = false

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(WhisperCppEngine.sampleRate),
        channels: 1, interleaved: false)!

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        converter = nil
        loggedFormat = false
    }

    func drain() -> [Float] {
        lock.lock()
        let result = samples
        samples.removeAll()
        lock.unlock()
        converter = nil
        return result
    }

    func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let pcm = AVAudioPCMBuffer(
                pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer) else { return }
            ingest(buffer: pcm)
        }
    }

    func ingest(buffer: AVAudioPCMBuffer) {
        if !loggedFormat {
            loggedFormat = true
            Log.info("capture buffer format: \(buffer.format.sampleRate)Hz \(buffer.format.channelCount)ch \(buffer.format.commonFormat == .pcmFormatFloat32 ? "float32" : "other")")
        }
        if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            onLevel?((sum / Float(buffer.frameLength)).squareRoot())
        }

        // Already the target format: append directly, no resampler in the path.
        if buffer.format.sampleRate == Self.targetFormat.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           let channel = buffer.floatChannelData?[0] {
            lock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            lock.unlock()
            return
        }

        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            if converter == nil {
                Log.error("cannot convert \(buffer.format.sampleRate)Hz \(buffer.format.channelCount)ch to 16kHz mono")
                return
            }
        }
        guard let converter else { return }

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
