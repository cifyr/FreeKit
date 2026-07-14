import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import FreeKitCore

enum ClopError: LocalizedError {
    case unreadableImage(detail: String)
    case animatedImage(frames: Int)
    case encodeFailed(format: String, detail: String)
    case unreadablePDF(detail: String)
    case exportPresetUnsupported(preset: String, file: String)
    case exportFailed(file: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let detail):
            return "Could not decode image (\(detail))"
        case .animatedImage(let frames):
            return "Animated image left untouched (\(frames) frames would flatten to one)"
        case .encodeFailed(let format, let detail):
            return "Could not encode \(format): \(detail)"
        case .unreadablePDF(let detail):
            return "Could not read PDF (\(detail))"
        case .exportPresetUnsupported(let preset, let file):
            return "Export preset \(preset) is not available for \(file)"
        case .exportFailed(let file, let underlying):
            return "Video export failed for \(file): \(underlying.localizedDescription)"
        }
    }
}

// Menu chips map straight onto AVFoundation's named presets; 720p is the one
// H.264 option for targets that cannot play HEVC.
enum ClopVideoPreset: String, CaseIterable {
    case sd720, hd1080, uhd4K, best

    var displayName: String {
        switch self {
        case .sd720: return "720p H.264"
        case .hd1080: return "1080p HEVC"
        case .uhd4K: return "4K HEVC"
        case .best: return "Highest HEVC"
        }
    }

    var avPreset: String {
        switch self {
        case .sd720: return AVAssetExportPreset1280x720
        case .hd1080: return AVAssetExportPresetHEVC1920x1080
        case .uhd4K: return AVAssetExportPresetHEVC3840x2160
        case .best: return AVAssetExportPresetHEVCHighestQuality
        }
    }
}

// On-device re-encoders. Every caller applies ClopPlan.keepResult afterwards;
// these only produce a candidate payload, never decide whether to use it.
enum ClopOptimizer {
    struct ImageResult {
        let data: Data
        let type: UTType
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif"]

    static func mediaType(forFileExtension ext: String) -> ClopPlan.MediaType? {
        let lower = ext.lowercased()
        if imageExtensions.contains(lower) { return .image }
        guard let type = UTType(filenameExtension: lower) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .pdf) { return .pdf }
        return nil
    }

    static func optimizeImage(_ data: Data, plan: ClopPlan,
                              sourceHint: UTType? = nil) throws -> ImageResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ClopError.unreadableImage(detail: "\(data.count) bytes, unrecognized data")
        }
        if plan.lossless {
            return losslessRewrite(source: source, originalData: data, sourceHint: sourceHint)
        }
        // Flattening a multi-frame GIF to one frame would lose the animation,
        // which counts as destroying data no matter how many bytes it saves.
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            throw ClopError.animatedImage(frames: frameCount)
        }
        let sourceType = sourceHint
            ?? (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let target = ClopPlan.targetSize(width: width, height: height,
                                         maxDimension: plan.maxDimension)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bakes EXIF orientation into the pixels, which matters because the
            // re-encode below strips the orientation tag with the rest of the metadata.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height, 1),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary) else {
            throw ClopError.unreadableImage(
                detail: "decode failed, \(width)x\(height) \(sourceType?.identifier ?? "unknown type")")
        }
        // The transparency scan is only paid when the answer can change the
        // outcome, i.e. when the policy would convert to JPEG.
        let sourceHasAlpha = plan.outputFormat == .jpeg && hasTransparentPixels(cgImage)
        let format = ClopPlan.effectiveFormat(policy: plan.outputFormat,
                                              sourceHasAlpha: sourceHasAlpha)
        if format != plan.outputFormat {
            Log.info("clop: transparent image keeps its format (JPEG would matte alpha onto a solid background)")
        }
        let outputType: UTType
        switch format {
        case .jpeg: outputType = .jpeg
        case .heic: outputType = .heic
        case .keep: outputType = sourceType ?? .png
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, outputType.identifier as CFString, 1, nil) else {
            throw ClopError.encodeFailed(format: outputType.identifier, detail: "no encoder for type")
        }
        // Only quality and density are passed: not copying the source
        // properties is what strips EXIF/GPS, and stripped metadata is part of
        // the contract. Density is re-derived (scaled by the downscale factor)
        // because dropping it makes Retina screenshots paste at twice their size.
        var encodeOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: plan.quality,
        ]
        if let sourceDPI = properties?[kCGImagePropertyDPIWidth] as? Double,
           let scaled = ClopPlan.scaledDensity(sourceDensity: sourceDPI, sourceWidth: width,
                                               targetWidth: cgImage.width) {
            encodeOptions[kCGImagePropertyDPIWidth] = scaled
            encodeOptions[kCGImagePropertyDPIHeight] =
                (properties?[kCGImagePropertyDPIHeight] as? Double).flatMap {
                    ClopPlan.scaledDensity(sourceDensity: $0, sourceWidth: width,
                                           targetWidth: cgImage.width)
                } ?? scaled
        }
        CGImageDestinationAddImage(destination, cgImage, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination), out.length > 0 else {
            throw ClopError.encodeFailed(format: outputType.identifier, detail: "finalize failed")
        }
        return ImageResult(data: out as Data, type: outputType,
                           pixelWidth: cgImage.width, pixelHeight: cgImage.height)
    }

    // Pixels are never re-encoded here: CGImageDestinationCopyImageSource
    // rewrites the container as-is with metadata replaced by an empty set
    // (EXIF/GPS/XMP stripped). Animated GIFs pass through intact because
    // nothing is flattened. For PNGs a full re-encode is also tried; PNG is a
    // lossless format, so that path is pixel-identical too and sometimes
    // compresses better. The keep-if-smaller rule upstream discards whichever
    // result did not help.
    private static func losslessRewrite(source: CGImageSource, originalData: Data,
                                        sourceHint: UTType?) -> ImageResult {
        let sourceType = sourceHint
            ?? (CGImageSourceGetType(source) as String?).flatMap { UTType($0) } ?? .png
        let frameCount = max(1, CGImageSourceGetCount(source))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0

        // Some formats (GIF today) refuse lossless metadata modification, so
        // fall back to a plain lossless copy, and past that to the original
        // bytes untouched: lossless mode must never fail on a passthrough,
        // and keep-if-smaller upstream reports an unchanged payload honestly.
        let stripOptions: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
        ]
        var best: Data
        if let stripped = losslessCopy(source: source, type: sourceType,
                                       frameCount: frameCount, options: stripOptions) {
            best = stripped
        } else if let copied = losslessCopy(source: source, type: sourceType,
                                            frameCount: frameCount, options: nil) {
            Log.info("clop: lossless metadata strip unsupported for \(sourceType.identifier), kept metadata")
            best = copied
        } else {
            Log.info("clop: lossless rewrite unsupported for \(sourceType.identifier), passing original through")
            best = originalData
        }

        if sourceType == .png, frameCount == 1,
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
               kCGImageSourceShouldCacheImmediately: true,
           ] as CFDictionary) {
            let reencoded = NSMutableData()
            if let pngDestination = CGImageDestinationCreateWithData(
                reencoded, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(pngDestination, cgImage, nil)
                if CGImageDestinationFinalize(pngDestination),
                   reencoded.length > 0, reencoded.length < best.count {
                    best = reencoded as Data
                }
            }
        }
        return ImageResult(data: best, type: sourceType,
                           pixelWidth: width, pixelHeight: height)
    }

    private static func losslessCopy(source: CGImageSource, type: UTType,
                                     frameCount: Int, options: [CFString: Any]?) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, type.identifier as CFString, frameCount, nil) else { return nil }
        var copyError: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source,
                                                options as CFDictionary?, &copyError),
              out.length > 0 else {
            if let copyError {
                Log.info("clop: lossless copy for \(type.identifier) failed: \(copyError.takeRetainedValue())")
            }
            return nil
        }
        return out as Data
    }

    // An alpha channel in the pixel format does not mean actual transparency
    // (opaque PNG screenshots usually carry one), so the real coverage is
    // scanned on the already-downscaled image. Values just under 255 count as
    // opaque: resampling jitter should not defeat JPEG conversion.
    private static func hasTransparentPixels(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            // Unverifiable coverage assumes transparency: keeping the source
            // format is the direction that cannot destroy anything.
            return true
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return true }
        let buffer = data.assumingMemoryBound(to: UInt8.self)
        // RGBA8 layout puts alpha at every fourth byte.
        for row in 0..<height {
            let base = row * context.bytesPerRow
            for column in 0..<width where buffer[base + column * 4 + 3] < 250 {
                return true
            }
        }
        return false
    }

    static func optimizePDF(_ data: Data) throws -> Data {
        guard let document = PDFDocument(data: data) else {
            throw ClopError.unreadablePDF(detail: "\(data.count) bytes")
        }
        let options: [PDFDocumentWriteOption: Any] = [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ]
        guard let optimized = document.dataRepresentation(options: options) else {
            throw ClopError.encodeFailed(format: "pdf", detail: "dataRepresentation returned nil")
        }
        return optimized
    }

    // Exports to a caller-chosen temp URL the caller owns (moves into place or
    // deletes). Cancelling the surrounding task cancels the export. Progress
    // lands on the main queue for the menu-bar readout.
    static func optimizeVideo(at url: URL, preset: String, outputURL: URL,
                              onProgress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ClopError.exportPresetUnsupported(preset: preset, file: url.lastPathComponent)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        Log.info("clop: video export start \(url.lastPathComponent) preset=\(preset)")
        let monitor = Task {
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let progress) = state {
                    let fraction = progress.fractionCompleted
                    DispatchQueue.main.async { onProgress(fraction) }
                }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: outputURL, as: .mp4)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        } catch {
            throw ClopError.exportFailed(file: url.lastPathComponent, underlying: error)
        }
        return outputURL
    }

    // Temp home for clipboard video exports: the file URL lands on the
    // pasteboard, so its name is what the user sees when pasting into Finder.
    static func clipboardVideoOutputURL(for source: URL) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clop-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("\(source.deletingPathExtension().lastPathComponent) (clopped).mp4")
    }

    static func batchVideoOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clop-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
    }
}
