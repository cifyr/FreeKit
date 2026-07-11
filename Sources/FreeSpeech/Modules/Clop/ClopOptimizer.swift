import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import FreeSpeechCore

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
        let outputType: UTType
        switch plan.outputFormat {
        case .jpeg: outputType = .jpeg
        case .heic: outputType = .heic
        case .keep: outputType = sourceType ?? .png
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, outputType.identifier as CFString, 1, nil) else {
            throw ClopError.encodeFailed(format: outputType.identifier, detail: "no encoder for type")
        }
        // Only the quality key is passed: not copying the source properties is
        // what strips EXIF/GPS, and stripped metadata is part of the contract.
        let encodeOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: plan.quality,
        ]
        CGImageDestinationAddImage(destination, cgImage, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination), out.length > 0 else {
            throw ClopError.encodeFailed(format: outputType.identifier, detail: "finalize failed")
        }
        return ImageResult(data: out as Data, type: outputType,
                           pixelWidth: cgImage.width, pixelHeight: cgImage.height)
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

    // Exports to a temp file the caller owns (moves into place or deletes).
    // Progress lands on the main queue for the menu-bar readout.
    static func optimizeVideo(at url: URL, preset: String,
                              onProgress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ClopError.exportPresetUnsupported(preset: preset, file: url.lastPathComponent)
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clop-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
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
        } catch {
            throw ClopError.exportFailed(file: url.lastPathComponent, underlying: error)
        }
        return outputURL
    }
}
