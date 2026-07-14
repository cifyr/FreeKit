import Foundation

// Verbose boundary logging to stderr and a file so failures can be reconstructed.
public enum Log {
    public private(set) static var logFileURL: URL?
    private static let queue = DispatchQueue(label: "com.cadenwarren.freespeech.log")
    private static var handle: FileHandle?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func setLogFile(_ url: URL) {
        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let h = try FileHandle(forWritingTo: url)
                h.seekToEndOfFile()
                handle = h
                logFileURL = url
            } catch {
                FileHandle.standardError.write(
                    Data("freespeech: cannot open log file \(url.path): \(error)\n".utf8))
            }
        }
    }

    public static func info(_ message: String) { write("INFO", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            handle?.write(Data(line.utf8))
        }
    }
}
