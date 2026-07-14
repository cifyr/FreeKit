import Foundation

// Decision layer for the Convert module: format tables, extension -> media-kind
// classification, and output naming, kept pure so they're unit-testable
// without linking ImageIO/AVFoundation/AppKit. Encoding itself (ImageIO,
// AVFoundation, NSAttributedString, PDFKit) lives in the app target's
// ConvertEngine.
public enum ConvertPlan {
    // PDF gets its own kind rather than folding into `document`: its source
    // and target formats (rasterize a page, extract text) are a different
    // shape from the NSAttributedString-based document formats.
    public enum MediaKind: String, CaseIterable {
        case image, audio, video, document, pdf
    }

    // `.pdf` wraps the image as a single-page PDF instead of an ImageIO re-encode.
    public enum ImageFormat: String, CaseIterable {
        case png, jpeg, heic, tiff, bmp, pdf

        public var displayName: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .tiff: return "TIFF"
            case .bmp: return "BMP"
            case .pdf: return "PDF"
            }
        }

        public var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .tiff: return "tiff"
            case .bmp: return "bmp"
            case .pdf: return "pdf"
            }
        }
    }

    // m4a re-encodes through AVAssetExportSession; the PCM containers (wav,
    // aiff, caf) go through AVAudioFile + AVAudioConverter since there is no
    // export preset for uncompressed audio.
    public enum AudioFormat: String, CaseIterable {
        case m4a, wav, aiff, caf

        public var displayName: String {
            switch self {
            case .m4a: return "M4A (AAC)"
            case .wav: return "WAV"
            case .aiff: return "AIFF"
            case .caf: return "CAF"
            }
        }

        public var fileExtension: String { rawValue }
    }

    public enum VideoFormat: String, CaseIterable {
        case mp4H264, mp4HEVC, mov

        public var displayName: String {
            switch self {
            case .mp4H264: return "MP4 (H.264)"
            case .mp4HEVC: return "MP4 (HEVC)"
            case .mov: return "MOV (HEVC)"
            }
        }

        public var fileExtension: String {
            switch self {
            case .mp4H264, .mp4HEVC: return "mp4"
            case .mov: return "mov"
            }
        }
    }

    // Every case but `.pdf` round-trips through NSAttributedString read/write
    // (verified: rtfd needs a file-wrapper/directory write, the rest are
    // plain data). `.pdf` renders the loaded attributed string through a
    // headless NSPrintOperation instead, so styling survives but the result
    // is no longer editable text.
    public enum DocumentFormat: String, CaseIterable {
        case plainText, rtf, rtfd, docx, doc, html, odt, pdf

        public var displayName: String {
            switch self {
            case .plainText: return "Plain Text"
            case .rtf: return "RTF"
            case .rtfd: return "RTFD"
            case .docx: return "Word (.docx)"
            case .doc: return "Word 97 (.doc)"
            case .html: return "HTML"
            case .odt: return "OpenDocument (.odt)"
            case .pdf: return "PDF"
            }
        }

        public var fileExtension: String {
            switch self {
            case .plainText: return "txt"
            case .rtf: return "rtf"
            case .rtfd: return "rtfd"
            case .docx: return "docx"
            case .doc: return "doc"
            case .html: return "html"
            case .odt: return "odt"
            case .pdf: return "pdf"
            }
        }
    }

    // A PDF source has no single natural target type the way the other kinds
    // do, so it gets its own small enum rather than reusing ImageFormat or
    // DocumentFormat wholesale. Multi-page PDFs only rasterize page one for
    // the image targets; plain text extracts every page.
    public enum PDFTarget: String, CaseIterable {
        case png, jpeg, plainText

        public var displayName: String {
            switch self {
            case .png: return "PNG (page 1)"
            case .jpeg: return "JPEG (page 1)"
            case .plainText: return "Plain Text (all pages)"
            }
        }

        public var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .plainText: return "txt"
            }
        }
    }

    public enum FileDestination: String, CaseIterable {
        case alongside, replace

        public var displayName: String {
            switch self {
            case .alongside: return "Save alongside"
            case .replace: return "Replace file"
            }
        }
    }

    // The user's configured target per kind; a dropped file's extension picks
    // which of these applies.
    public struct Target: Equatable {
        public var image: ImageFormat
        public var audio: AudioFormat
        public var video: VideoFormat
        public var document: DocumentFormat
        public var pdf: PDFTarget
        public var destination: FileDestination

        public init(image: ImageFormat = .jpeg, audio: AudioFormat = .m4a,
                    video: VideoFormat = .mp4HEVC, document: DocumentFormat = .pdf,
                    pdf: PDFTarget = .png, destination: FileDestination = .alongside) {
            self.image = image
            self.audio = audio
            self.video = video
            self.document = document
            self.pdf = pdf
            self.destination = destination
        }

        // A copy of `base` with exactly one kind's format overridden, used by
        // the Finder "Convert to X" services: each one forces a specific
        // format for its kind while every other kind stays at whatever the
        // user has configured. Returns nil for a stale/unrecognized rawValue
        // (e.g. a plist entry left over from an older build).
        public static func overriding(kind: MediaKind, rawValue: String, base: Target) -> Target? {
            var target = base
            switch kind {
            case .image:
                guard let format = ImageFormat(rawValue: rawValue) else { return nil }
                target.image = format
            case .audio:
                guard let format = AudioFormat(rawValue: rawValue) else { return nil }
                target.audio = format
            case .video:
                guard let format = VideoFormat(rawValue: rawValue) else { return nil }
                target.video = format
            case .document:
                guard let format = DocumentFormat(rawValue: rawValue) else { return nil }
                target.document = format
            case .pdf:
                guard let format = PDFTarget(rawValue: rawValue) else { return nil }
                target.pdf = format
            }
            return target
        }

        // The extension a given source file would land on with this target
        // configuration, or nil if its kind is unrecognized.
        public func outputExtension(forSourceExtension ext: String) -> String? {
            guard let kind = ConvertPlan.mediaKind(forFileExtension: ext) else { return nil }
            switch kind {
            case .image: return image.fileExtension
            case .audio: return audio.fileExtension
            case .video: return video.fileExtension
            case .document: return document.fileExtension
            case .pdf: return pdf.fileExtension
            }
        }
    }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif"]
    public static let audioExtensions: Set<String> = ["m4a", "wav", "aiff", "aif", "caf", "mp3", "aac"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi"]
    public static let documentExtensions: Set<String> = ["txt", "rtf", "rtfd", "docx", "doc", "html", "htm", "odt"]
    public static let pdfExtensions: Set<String> = ["pdf"]

    public static func mediaKind(forFileExtension ext: String) -> MediaKind? {
        let lower = ext.lowercased()
        if imageExtensions.contains(lower) { return .image }
        if audioExtensions.contains(lower) { return .audio }
        if videoExtensions.contains(lower) { return .video }
        if documentExtensions.contains(lower) { return .document }
        if pdfExtensions.contains(lower) { return .pdf }
        return nil
    }

    // A file already sitting in its target extension has nothing to convert;
    // callers use this to skip with "already <format>" instead of doing a
    // no-op re-encode.
    public static func needsConversion(currentExtension: String, targetExtension: String) -> Bool {
        currentExtension.lowercased() != targetExtension.lowercased()
    }

    // "photo.png" -> "photo (converted).jpg", stepping to "(converted 2)" and
    // on so an existing sibling is never overwritten.
    public static func siblingURL(for url: URL, targetExtension: String,
                                  fileExists: (URL) -> Bool) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var attempt = 0
        while true {
            attempt += 1
            let suffix = attempt == 1 ? " (converted)" : " (converted \(attempt))"
            let candidate = directory.appendingPathComponent(base + suffix)
                .appendingPathExtension(targetExtension)
            if !fileExists(candidate) { return candidate }
        }
    }

    // Replace mode's honest rename: "shot.png" targeting jpg becomes
    // "shot.jpg" in the same directory. Falls back to the sibling naming if
    // that name is already taken by an unrelated file.
    public static func replacementURL(for url: URL, targetExtension: String,
                                      fileExists: (URL) -> Bool) -> URL {
        let renamed = url.deletingPathExtension().appendingPathExtension(targetExtension)
        if !fileExists(renamed) { return renamed }
        return siblingURL(for: url, targetExtension: targetExtension, fileExists: fileExists)
    }

    // Backups keep the original filename so they are recognizable; a name
    // collision steps to "name 2.ext" rather than clobbering an older backup.
    public static func backupURL(for url: URL, in directory: URL,
                                 fileExists: (URL) -> Bool) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var attempt = 0
        while true {
            attempt += 1
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            var candidate = directory.appendingPathComponent(name)
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fileExists(candidate) { return candidate }
        }
    }

    // "document.pdf" page 3 -> "document-page-3.jpg", stepping to a
    // "(2)" suffix on an unlikely collision (splitting the same PDF twice
    // into the same folder without cleaning up first).
    public static func pageNumberedURL(for url: URL, page: Int, targetExtension: String,
                                       fileExists: (URL) -> Bool) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var attempt = 0
        while true {
            attempt += 1
            let suffix = attempt == 1 ? "-page-\(page)" : "-page-\(page) (\(attempt))"
            let candidate = directory.appendingPathComponent(base + suffix)
                .appendingPathExtension(targetExtension)
            if !fileExists(candidate) { return candidate }
        }
    }

    // "Combined.pdf" in `directory`, stepping to "Combined 2.pdf" and on so
    // an earlier combine result in the same folder is never overwritten.
    public static func combinedPDFURL(baseName: String, in directory: URL,
                                      fileExists: (URL) -> Bool) -> URL {
        var attempt = 0
        while true {
            attempt += 1
            let name = attempt == 1 ? baseName : "\(baseName) \(attempt)"
            let candidate = directory.appendingPathComponent(name).appendingPathExtension("pdf")
            if !fileExists(candidate) { return candidate }
        }
    }
}
