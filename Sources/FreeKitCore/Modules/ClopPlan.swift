import Foundation

// Decision layer for the Clop compressor, kept pure so the watch gate, sizing
// math, keep-if-smaller rule, and naming schemes are unit-testable. Encoding
// itself (ImageIO/AVFoundation/PDFKit) lives in the app target.
public struct ClopPlan: Equatable {
    public enum MediaType: String, CaseIterable {
        case image, video, pdf
    }

    public enum OutputFormat: String, CaseIterable {
        case keep, jpeg, heic

        public var displayName: String {
            switch self {
            case .keep: return "Keep format"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
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

    // Which half of the drop zone the file landed on. Keeping the original
    // format is what makes replace mode safe: the file keeps its exact path and
    // extension, so a dropped PNG stays a (smaller) PNG instead of turning into
    // a JPEG and leaving its old path empty.
    public enum FormatMode: String, CaseIterable {
        case keepOriginal, convert

        public var displayName: String {
            switch self {
            case .keepOriginal: return "Keep format"
            case .convert: return "Convert"
            }
        }
    }

    // Video always exports as mp4, so "convert" is what lets the extension
    // follow the container; keepOriginal leaves the name alone.
    public static let videoConvertedExtension = "mp4"

    public func applying(_ mode: FormatMode) -> ClopPlan {
        var copy = self
        switch mode {
        case .keepOriginal:
            copy.outputFormat = .keep
        case .convert:
            // "Convert" needs a format to aim at; a plan already set to keep has
            // none, so fall back to the usual baseline for images.
            copy.outputFormat = outputFormat == .keep ? .jpeg : outputFormat
        }
        return copy
    }

    public enum SkipReason: String, Equatable {
        case ownWrite, typeDisabled, belowSizeFloor
    }

    public enum Decision: Equatable {
        case process
        case skip(SkipReason)
    }

    // Bounds keep a mistyped value from producing garbage: quality near zero
    // encodes unusable images, a savings floor past 90% would skip everything.
    public static let qualityRange: ClosedRange<Double> = 0.1...1.0
    public static let minimumSavingsRange: ClosedRange<Double> = 0...0.9

    public var imagesEnabled: Bool
    public var videosEnabled: Bool
    public var pdfsEnabled: Bool
    public var quality: Double
    // Lossless never touches pixels: metadata is stripped and the container
    // rewritten, so quality, downscale, and format conversion do not apply.
    public var lossless: Bool
    // nil = no downscale.
    public var maxDimension: Int?
    public var outputFormat: OutputFormat
    // Fraction of the original that must be saved before a result is kept.
    public var minimumSavings: Double
    // Payloads under this many bytes are not worth touching.
    public var skipBelowBytes: Int
    public var fileDestination: FileDestination

    public init(imagesEnabled: Bool = true, videosEnabled: Bool = false,
                pdfsEnabled: Bool = false, quality: Double = 0.75,
                lossless: Bool = false,
                maxDimension: Int? = nil, outputFormat: OutputFormat = .jpeg,
                minimumSavings: Double = 0.10, skipBelowBytes: Int = 10_240,
                fileDestination: FileDestination = .alongside) {
        self.imagesEnabled = imagesEnabled
        self.videosEnabled = videosEnabled
        self.pdfsEnabled = pdfsEnabled
        self.quality = min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound)
        self.lossless = lossless
        // A tiny cap would destroy images; anything under 64px means "off" was intended.
        self.maxDimension = maxDimension.flatMap { $0 >= 64 ? $0 : nil }
        self.outputFormat = outputFormat
        self.minimumSavings = min(max(minimumSavings, Self.minimumSavingsRange.lowerBound),
                                  Self.minimumSavingsRange.upperBound)
        self.skipBelowBytes = max(0, skipBelowBytes)
        self.fileDestination = fileDestination
    }

    public func isEnabled(_ type: MediaType) -> Bool {
        switch type {
        case .image: return imagesEnabled
        case .video: return videosEnabled
        case .pdf: return pdfsEnabled
        }
    }

    // The clipboard-watch gate. Own writes are checked first: the watcher sees
    // its own pasteboard writes as changes and must never re-process them.
    public func shouldProcess(type: MediaType, byteCount: Int, isOwnWrite: Bool) -> Decision {
        if isOwnWrite { return .skip(.ownWrite) }
        guard isEnabled(type) else { return .skip(.typeDisabled) }
        guard byteCount >= skipBelowBytes else { return .skip(.belowSizeFloor) }
        return .process
    }

    // Aspect-preserving fit of the longest edge to maxDimension; never upscales.
    public static func targetSize(width: Int, height: Int,
                                  maxDimension: Int?) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (max(0, width), max(0, height)) }
        guard let maxDimension, maxDimension > 0, max(width, height) > maxDimension else {
            return (width, height)
        }
        let scale = Double(maxDimension) / Double(max(width, height))
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    // The only-if-smaller rule: a result that does not clear the savings floor
    // is discarded and the original stays in place. Non-positive sizes mean an
    // encode went wrong, so nothing is ever kept for them.
    public static func keepResult(originalBytes: Int, optimizedBytes: Int,
                                  minimumSavings: Double) -> Bool {
        guard originalBytes > 0, optimizedBytes > 0, optimizedBytes < originalBytes else {
            return false
        }
        let saved = Double(originalBytes - optimizedBytes) / Double(originalBytes)
        return saved >= minimumSavings
    }

    public func keepResult(originalBytes: Int, optimizedBytes: Int) -> Bool {
        Self.keepResult(originalBytes: originalBytes, optimizedBytes: optimizedBytes,
                        minimumSavings: minimumSavings)
    }

    // "photo.png" -> "photo (clopped).png", stepping to "(clopped 2)" and on so
    // an existing sibling is never overwritten. preferredExtension covers
    // format conversion ("photo (clopped).jpg" next to a png).
    public static func siblingURL(for url: URL, preferredExtension: String? = nil,
                                  fileExists: (URL) -> Bool) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = preferredExtension ?? url.pathExtension
        var attempt = 0
        while true {
            attempt += 1
            let suffix = attempt == 1 ? " (clopped)" : " (clopped \(attempt))"
            var candidate = directory.appendingPathComponent(base + suffix)
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fileExists(candidate) { return candidate }
        }
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

    // JPEG cannot store alpha, so converting a transparent image would matte
    // it onto a solid background (window screenshots carry alpha shadows).
    // Transparent sources keep their own format instead; HEIC keeps alpha and
    // needs no fallback.
    public static func effectiveFormat(policy: OutputFormat,
                                       sourceHasAlpha: Bool) -> OutputFormat {
        policy == .jpeg && sourceHasAlpha ? .keep : policy
    }

    // Pixel density must scale with any downscale or the pasted image changes
    // its point size: a 144dpi Retina screenshot halved to 72dpi keeps the
    // same on-screen bounds. nil means the source had no usable density.
    public static func scaledDensity(sourceDensity: Double, sourceWidth: Int,
                                     targetWidth: Int) -> Double? {
        guard sourceDensity > 0, sourceWidth > 0, targetWidth > 0 else { return nil }
        return sourceDensity * Double(targetWidth) / Double(sourceWidth)
    }

    public static func totalSummary(savedBytes: Int, items: Int) -> String {
        let count = max(0, items)
        return "Saved \(StatsFormatting.bytes(Double(max(0, savedBytes)))) total across \(count) item\(count == 1 ? "" : "s")"
    }

    public static func savingsSummary(originalBytes: Int, optimizedBytes: Int) -> String {
        let saved = max(0, originalBytes - optimizedBytes)
        let fraction = originalBytes > 0 ? Double(saved) / Double(originalBytes) : 0
        return "Saved \(StatsFormatting.bytes(Double(saved))) (\(StatsFormatting.percent(fraction)))"
    }
}
