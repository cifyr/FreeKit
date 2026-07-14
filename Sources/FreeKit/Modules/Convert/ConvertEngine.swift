import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import FreeKitCore

enum ConvertError: LocalizedError {
    case unreadableImage(detail: String)
    case animatedImage(frames: Int)
    case encodeFailed(format: String, detail: String)
    case unreadableDocument(underlying: Error)
    case unreadablePDF(detail: String)
    case emptyPDF
    case rasterizeFailed
    case exportPresetUnsupported(preset: String, file: String)
    case exportFailed(file: String, underlying: Error)
    case printFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let detail):
            return "Could not decode image (\(detail))"
        case .animatedImage(let frames):
            return "Animated image left untouched (\(frames) frames would flatten to one)"
        case .encodeFailed(let format, let detail):
            return "Could not encode \(format): \(detail)"
        case .unreadableDocument(let underlying):
            return "Could not read document: \(underlying.localizedDescription)"
        case .unreadablePDF(let detail):
            return "Could not read PDF (\(detail))"
        case .emptyPDF:
            return "PDF has no pages"
        case .rasterizeFailed:
            return "Could not rasterize PDF page"
        case .exportPresetUnsupported(let preset, let file):
            return "Export preset \(preset) is not available for \(file)"
        case .exportFailed(let file, let underlying):
            return "Export failed for \(file): \(underlying.localizedDescription)"
        case .printFailed:
            return "Could not render document to PDF"
        }
    }
}

// On-device re-encoders backing the Convert module. Every path here is
// exercised end to end (round-tripped through a real encoder/decoder) rather
// than assumed from API docs, since a few of these (NSAttributedString's
// package-vs-data document writers, JPEG alpha matting, headless print-to-PDF)
// have sharp edges that silently produce corrupt output if used the naive way.
enum ConvertEngine {

    // MARK: - Images

    static func convertImage(at url: URL, to format: ConvertPlan.ImageFormat, quality: Double = 0.92) throws -> Data {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ConvertError.unreadableImage(detail: "\(data.count) bytes, unrecognized data")
        }
        // Flattening a multi-frame GIF to one frame would destroy the
        // animation no matter the target format.
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            throw ConvertError.animatedImage(frames: frameCount)
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else {
            throw ConvertError.unreadableImage(detail: "decode failed")
        }
        if format == .pdf {
            let document = PDFDocument()
            document.insert(try pdfPage(for: cgImage), at: 0)
            guard let data = document.dataRepresentation() else {
                throw ConvertError.encodeFailed(format: "pdf", detail: "dataRepresentation returned nil")
            }
            return data
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let outputType: UTType
        switch format {
        case .png: outputType = .png
        case .jpeg: outputType = .jpeg
        case .heic: outputType = .heic
        case .tiff: outputType = .tiff
        case .bmp: outputType = UTType("com.microsoft.bmp") ?? .bmp
        case .pdf: fatalError("handled above")
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, outputType.identifier as CFString, 1, nil) else {
            throw ConvertError.encodeFailed(format: outputType.identifier, detail: "no encoder for type")
        }
        // Carrying the source properties through (unlike Clop's deliberate
        // strip) keeps EXIF/orientation/DPI intact: this is an explicit
        // format conversion, not a silent background optimization.
        var options: [CFString: Any] = properties ?? [:]
        if format == .jpeg || format == .heic {
            // JPEG has no alpha channel; ImageIO mattes transparent pixels
            // onto white automatically rather than the black some older
            // encoders default to (verified against a known-transparent
            // source), so no manual compositing pass is needed here.
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), out.length > 0 else {
            throw ConvertError.encodeFailed(format: outputType.identifier, detail: "finalize failed")
        }
        return out as Data
    }

    // Shared by the single-image "convert to PDF" path and combineImagesToPDF.
    private static func pdfPage(for cgImage: CGImage) throws -> PDFPage {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let page = PDFPage(image: image) else {
            throw ConvertError.encodeFailed(format: "pdf", detail: "PDFPage init failed")
        }
        return page
    }

    // Combines N images (in order) into one multi-page PDF, for the App tab's
    // "combine into one PDF" action. Animated sources are rejected the same
    // way convertImage rejects them: a flattened frame would misrepresent them.
    static func combineImagesToPDF(_ urls: [URL]) throws -> Data {
        let document = PDFDocument()
        for (index, url) in urls.enumerated() {
            let data = try Data(contentsOf: url)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw ConvertError.unreadableImage(detail: url.lastPathComponent)
            }
            let frameCount = CGImageSourceGetCount(source)
            if frameCount > 1 {
                throw ConvertError.animatedImage(frames: frameCount)
            }
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else {
                throw ConvertError.unreadableImage(detail: "\(url.lastPathComponent): decode failed")
            }
            document.insert(try pdfPage(for: cgImage), at: index)
        }
        guard let data = document.dataRepresentation() else {
            throw ConvertError.encodeFailed(format: "pdf", detail: "dataRepresentation returned nil")
        }
        return data
    }

    static let imageExtensions = ConvertPlan.imageExtensions

    // MARK: - Audio

    static func convertAudio(at url: URL, to format: ConvertPlan.AudioFormat, outputURL: URL) async throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch format {
        case .m4a:
            try await exportM4A(source: url, outputURL: outputURL)
        case .wav, .aiff, .caf:
            // No AVFoundation export preset covers uncompressed PCM
            // containers, so these go through AVAudioFile + AVAudioConverter
            // directly (verified end to end for all three extensions).
            try convertPCM(source: url, outputURL: outputURL)
        }
    }

    private static func exportM4A(source: URL, outputURL: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ConvertError.exportPresetUnsupported(preset: "AppleM4A", file: source.lastPathComponent)
        }
        do {
            try await session.export(to: outputURL, as: .m4a)
        } catch {
            throw ConvertError.exportFailed(file: source.lastPathComponent, underlying: error)
        }
    }

    private static func convertPCM(source: URL, outputURL: URL) throws {
        let inFile = try AVAudioFile(forReading: source)
        let processingFormat = inFile.processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: processingFormat.sampleRate,
            AVNumberOfChannelsKey: processingFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let ext = outputURL.pathExtension.lowercased()
        if ext == "aiff" || ext == "aif" {
            settings[AVLinearPCMIsBigEndianKey] = true
        }
        // commonFormat/interleaved must match the buffer written below: the
        // file's processing format silently defaults to float32
        // non-interleaved otherwise, and write(from:) crashes on a mismatch.
        let outFile = try AVAudioFile(forWriting: outputURL, settings: settings,
                                      commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(inFile.length)) else {
            throw ConvertError.encodeFailed(format: ext, detail: "buffer alloc failed")
        }
        try inFile.read(into: buffer)
        guard let destFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: processingFormat.sampleRate,
                channels: processingFormat.channelCount, interleaved: true),
              let converter = AVAudioConverter(from: processingFormat, to: destFormat),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: destFormat, frameCapacity: buffer.frameLength) else {
            throw ConvertError.encodeFailed(format: ext, detail: "converter setup failed")
        }
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw convError ?? ConvertError.encodeFailed(format: ext, detail: "conversion failed")
        }
        try outFile.write(from: outBuffer)
    }

    // MARK: - Video

    static func convertVideo(at url: URL, to format: ConvertPlan.VideoFormat, outputURL: URL,
                            onProgress: @escaping (Double) -> Void) async throws {
        let preset: String
        let fileType: AVFileType
        switch format {
        case .mp4H264:
            preset = AVAssetExportPreset1920x1080
            fileType = .mp4
        case .mp4HEVC:
            preset = AVAssetExportPresetHEVCHighestQuality
            fileType = .mp4
        case .mov:
            preset = AVAssetExportPresetHEVCHighestQuality
            fileType = .mov
        }
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError.exportPresetUnsupported(preset: preset, file: url.lastPathComponent)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
            try await session.export(to: outputURL, as: fileType)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        } catch {
            throw ConvertError.exportFailed(file: url.lastPathComponent, underlying: error)
        }
    }

    // MARK: - Documents

    enum DocumentResult {
        case data(Data)
        case fileWrapper(FileWrapper)
    }

    // Every format but RTFD round-trips through NSAttributedString's `data`
    // writer; RTFD is a directory package and needs the `fileWrapper` writer
    // instead (verified: `data(from:)` for RTFD silently returns a different,
    // non-bundle "flattened" serialization instead of throwing).
    static func convertDocument(at url: URL, to format: ConvertPlan.DocumentFormat) throws -> DocumentResult {
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw ConvertError.unreadableDocument(underlying: error)
        }
        let range = NSRange(location: 0, length: attributed.length)
        if format == .pdf {
            return .data(try renderPDF(attributed))
        }
        if format == .rtfd {
            guard let wrapper = try? attributed.fileWrapper(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) else {
                throw ConvertError.encodeFailed(format: "rtfd", detail: "fileWrapper failed")
            }
            return .fileWrapper(wrapper)
        }
        let docType: NSAttributedString.DocumentType
        switch format {
        case .plainText: docType = .plain
        case .rtf: docType = .rtf
        case .docx: docType = .officeOpenXML
        case .doc: docType = .docFormat
        case .html: docType = .html
        case .odt: docType = .openDocument
        case .rtfd, .pdf: fatalError("handled above")
        }
        do {
            let data = try attributed.data(from: range, documentAttributes: [.documentType: docType])
            return .data(data)
        } catch {
            throw ConvertError.encodeFailed(format: format.rawValue, detail: error.localizedDescription)
        }
    }

    // Headless "print to PDF": NSPrintOperation with jobDisposition = .save
    // paginates a text view across US Letter pages with no print panel and no
    // window on screen (verified against a multi-page document).
    private static func renderPDF(_ attributed: NSAttributedString) throws -> Data {
        let pageSize = NSSize(width: 612, height: 792)
        let margin: CGFloat = 72
        let textView = NSTextView(frame: NSRect(
            origin: .zero,
            size: NSSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attributed)
        textView.sizeToFit()

        let printInfo = NSPrintInfo()
        printInfo.paperSize = pageSize
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert-\(UUID().uuidString).pdf")
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tempURL

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), let data = try? Data(contentsOf: tempURL) else {
            throw ConvertError.printFailed
        }
        try? FileManager.default.removeItem(at: tempURL)
        return data
    }

    // MARK: - PDF sources

    static func rasterizeFirstPage(at url: URL, format: ConvertPlan.PDFTarget, quality: Double = 0.92) throws -> Data {
        guard let document = PDFDocument(url: url) else {
            throw ConvertError.unreadablePDF(detail: url.lastPathComponent)
        }
        guard document.pageCount > 0, let page = document.page(at: 0) else {
            throw ConvertError.emptyPDF
        }
        return try rasterize(page: page, format: format, quality: quality)
    }

    // Every page of the source PDF as its own JPEG, for the App tab's "split
    // into JPEGs" action. Always JPEG (unlike rasterizeFirstPage, which
    // supports PNG too) since a whole-document split is a size-conscious
    // operation the way a PDF viewer's "export as images" is.
    static func rasterizeAllPages(at url: URL, quality: Double = 0.92) throws -> [Data] {
        guard let document = PDFDocument(url: url) else {
            throw ConvertError.unreadablePDF(detail: url.lastPathComponent)
        }
        guard document.pageCount > 0 else {
            throw ConvertError.emptyPDF
        }
        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { throw ConvertError.rasterizeFailed }
            return try rasterize(page: page, format: .jpeg, quality: quality)
        }
    }

    private static func rasterize(page: PDFPage, format: ConvertPlan.PDFTarget, quality: Double) throws -> Data {
        let bounds = page.bounds(for: .mediaBox)
        // ~144dpi from a 72dpi PDF page: sharp enough for screen or print reuse.
        let scale: CGFloat = 2
        let pixelSize = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let thumbnail = page.thumbnail(of: pixelSize, for: .mediaBox)
        guard let tiff = thumbnail.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            throw ConvertError.rasterizeFailed
        }
        let fileType: NSBitmapImageRep.FileType = format == .png ? .png : .jpeg
        guard let data = rep.representation(using: fileType, properties: [.compressionFactor: quality]) else {
            throw ConvertError.rasterizeFailed
        }
        return data
    }

    // Multi-page PDFs concatenate every page's text; the image targets above
    // only take page one since there is no single-file raster equivalent for
    // "the rest of the pages".
    static func extractText(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ConvertError.unreadablePDF(detail: url.lastPathComponent)
        }
        guard document.pageCount > 0 else { throw ConvertError.emptyPDF }
        var text = ""
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) {
                text += (page.string ?? "") + "\n"
            }
        }
        return text
    }

    static func mediaType(forFileExtension ext: String) -> ConvertPlan.MediaKind? {
        ConvertPlan.mediaKind(forFileExtension: ext)
    }
}
