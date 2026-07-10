import Foundation
import FreeSpeechCore

enum ModelDownloadError: LocalizedError {
    case badModelName(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badModelName(let n): return "Unknown model \"\(n)\""
        case .httpStatus(let code): return "Download server returned HTTP \(code)"
        }
    }
}

// Fetches a whisper ggml model on first run when it isn't already on disk. This is the
// same one-time, local-only download build.sh performs, moved into the app so a shared
// copy self-provisions instead of shipping the multi-hundred-MB model in the bundle.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    // Official ggml conversions hosted by the whisper.cpp author (matches build.sh).
    static let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    private var progressHandler: ((Double) -> Void)?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var destination: URL?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    // tinydiarize models are hosted by their author, not in ggerganov's repo
    // (mirrors whisper.cpp's own download-ggml-model.sh).
    static func url(for modelName: String) -> URL? {
        let base = modelName.contains("tdrz")
            ? "https://huggingface.co/akashmjn/tinydiarize-whisper.cpp/resolve/main"
            : baseURL
        return URL(string: "\(base)/ggml-\(modelName).bin")
    }

    func download(modelName: String, to destination: URL,
                  progress: @escaping (Double) -> Void,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        guard let url = Self.url(for: modelName) else {
            completion(.failure(ModelDownloadError.badModelName(modelName)))
            return
        }
        self.progressHandler = progress
        self.completion = completion
        self.destination = destination
        Log.info("model download start: \(url.absoluteString) -> \(destination.path)")
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let destination else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            // HF returns an HTML error body with a non-200 status; never keep that as a model.
            completion?(.failure(ModelDownloadError.httpStatus(http.statusCode)))
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            Log.info("model download complete: \(destination.path)")
            completion?(.success(destination))
        } catch {
            completion?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is reported from didFinishDownloadingTo; this only surfaces transport errors.
        if let error {
            Log.error("model download failed: \(error.localizedDescription)")
            completion?(.failure(error))
        }
    }
}
