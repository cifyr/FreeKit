import AppKit
import SwiftUI
import FreeKitCore

// Convert: on-device format conversion for images, audio, video, and
// documents. Unlike Clop this never watches the clipboard passively — silently
// changing a file's format on every copy is far more likely to surprise
// someone than shrinking it is, so every conversion here is an explicit act
// (a drop, a hotkey, a Finder selection, a menu). Format decisions live in
// Core's ConvertPlan; this layer runs the encoders and places the results.
final class ConvertModule: NSObject, AppModule, NSMenuDelegate {
    let info = ModuleCatalog.convert

    private let settings: Settings
    private let hub: EventTapHub
    private let registry: ModuleRegistry
    private let dropZoneCoordinator: SuiteDropZoneCoordinator

    private var hotkeyToken: EventTapHub.HotkeyToken?
    private var finderHotkeyToken: EventTapHub.HotkeyToken?
    private var statusItem: NSStatusItem?
    private var active = false
    private var working = 0
    private enum IconState { case idle, working }
    private var lastIconState: IconState?
    private var videoProgress: Double?
    private var batchProgress: (done: Int, total: Int)?
    private var lastResult: String?
    private var lastUndo: FileUndo?
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private let paneModel = ConvertPaneModel()
    private var landOnToolTabNextOpen = false

    private struct FileUndo {
        let original: URL
        let backup: URL
        // Differs from original when the conversion renamed the extension;
        // undo removes it again so the folder returns to its exact prior state.
        let replacement: URL?
    }

    enum Key {
        static let imageFormat = "imageFormat"
        static let audioFormat = "audioFormat"
        static let videoFormat = "videoFormat"
        static let documentFormat = "documentFormat"
        static let pdfFormat = "pdfFormat"
        static let destination = "destination"
        static let dropZone = "dropZone"
        static let totalItems = "totalItems"
        static let toast = "toast"
        static let toastDuration = "toastDuration"
        static let toastLocation = "toastLocation"
        static let finderHotkeyCode = "finderHotkeyKeyCode"
        static let finderHotkeyMods = "finderHotkeyModifiers"
    }

    init(settings: Settings, hub: EventTapHub, registry: ModuleRegistry,
        dropZoneCoordinator: SuiteDropZoneCoordinator) {
        self.settings = settings
        self.hub = hub
        self.registry = registry
        self.dropZoneCoordinator = dropZoneCoordinator
        super.init()
    }

    private var hotkey: HotkeyPreset {
        settings.moduleHotkey(id: info.id, defaultPreset: .disabled)
    }

    // Second per-module hotkey, same dual-Int storage trick Clop uses since
    // the shared moduleHotkey helper only stores one.
    var finderHotkey: HotkeyPreset {
        guard let code = settings.moduleInt(id: info.id, key: Key.finderHotkeyCode),
              Int64(code) != HotkeyPreset.disabled.keyCode else { return .disabled }
        let modifiers = HotkeyModifiers(
            rawValue: UInt64(settings.moduleInt(id: info.id, key: Key.finderHotkeyMods) ?? 0))
        return .custom(keyCode: Int64(code), modifiers: modifiers)
    }

    func updateHotkey(_ preset: HotkeyPreset) {
        settings.setModuleHotkey(preset, id: info.id)
        if let hotkeyToken { hub.update(hotkeyToken, preset: preset) }
    }

    func updateFinderHotkey(_ preset: HotkeyPreset) {
        settings.setModuleInt(Int(preset.keyCode), id: info.id, key: Key.finderHotkeyCode)
        settings.setModuleInt(Int(preset.modifiers.rawValue), id: info.id, key: Key.finderHotkeyMods)
        if let finderHotkeyToken { hub.update(finderHotkeyToken, preset: preset) }
    }

    static func currentTarget(settings: Settings) -> ConvertPlan.Target {
        let id = ModuleCatalog.convert.id
        return ConvertPlan.Target(
            image: settings.moduleString(id: id, key: Key.imageFormat)
                .flatMap(ConvertPlan.ImageFormat.init) ?? .jpeg,
            audio: settings.moduleString(id: id, key: Key.audioFormat)
                .flatMap(ConvertPlan.AudioFormat.init) ?? .m4a,
            video: settings.moduleString(id: id, key: Key.videoFormat)
                .flatMap(ConvertPlan.VideoFormat.init) ?? .mp4HEVC,
            document: settings.moduleString(id: id, key: Key.documentFormat)
                .flatMap(ConvertPlan.DocumentFormat.init) ?? .pdf,
            pdf: settings.moduleString(id: id, key: Key.pdfFormat)
                .flatMap(ConvertPlan.PDFTarget.init) ?? .png,
            destination: settings.moduleString(id: id, key: Key.destination)
                .flatMap(ConvertPlan.FileDestination.init) ?? .alongside)
    }

    static var backupsDirectory: URL {
        AppPaths.appSupport.appendingPathComponent("convert-backups", isDirectory: true)
    }

    // MARK: - AppModule

    func activate() {
        active = true
        if hotkeyToken == nil {
            hotkeyToken = hub.register(preset: hotkey, label: "convert.convertClipboard") { [weak self] direction in
                if case .down = direction { self?.convertClipboardNow() }
            }
        }
        if finderHotkeyToken == nil {
            finderHotkeyToken = hub.register(
                preset: finderHotkey, label: "convert.convertFinderSelection") { [weak self] direction in
                if case .down = direction { self?.convertFinderSelection() }
            }
        }
        paneModel.module = self
        dropZoneCoordinator.onConvertDrop = { [weak self] urls in self?.convertFiles(urls) }
        dropZoneCoordinator.setConvertActive(dropZoneEnabled)
        // ownsMenuBarItem is true: the registry drives setMenuBarItemVisible from
        // the MENU checkbox right after this, so don't force the item on here.
        Log.info("convert: activated")
    }

    func deactivate() {
        active = false
        dropZoneCoordinator.setConvertActive(false)
        cancelAllWork()
        setMenuBarItemVisible(false)
        if let hotkeyToken { hub.unregister(hotkeyToken) }
        hotkeyToken = nil
        if let finderHotkeyToken { hub.unregister(finderHotkeyToken) }
        finderHotkeyToken = nil
        Log.info("convert: deactivated")
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.toolTip = "Convert \u{2014} drop files here to convert"
                item.button?.wantsLayer = true
                if let button = item.button {
                    let drop = ConvertDropView(frame: button.bounds)
                    drop.autoresizingMask = [.width, .height]
                    drop.toolTip = button.toolTip
                    drop.onDrop = { [weak self] urls in
                        Log.info("convert: \(urls.count) file(s) dropped on menu bar item")
                        self?.convertFiles(urls)
                    }
                    button.addSubview(drop)
                }
                let menu = NSMenu()
                menu.delegate = self
                item.menu = menu
                statusItem = item
                updateStatusIcon()
            }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    // Small popup-style window, sized like Notebook's floating panel; the
    // panes scroll inside it.
    var settingsPopupSize: NSSize { NSSize(width: 680, height: 460) }
    var opensOwnWindow: Bool { true }

    func openSettings() {
        landOnToolTabNextOpen = false
        ModuleWindowManager.shared.open(self)
    }

    // Called instead of openSettings() when Convert is opened via its Tools
    // tab proxy card (rather than its Apps tab home): that entry point reads
    // as configuring the tool, so it should land on the Tool tab, not App.
    func openSettingsOnToolTab() {
        landOnToolTabNextOpen = true
        ModuleWindowManager.shared.open(self)
    }

    func makeSettingsPane() -> AnyView {
        paneModel.module = self
        let initialTab: ConvertSettingsPane.InitialTab = landOnToolTabNextOpen ? .tool : .app
        return AnyView(ConvertSettingsPane(model: paneModel, settings: settings, registry: registry, initialTab: initialTab))
    }

    // MARK: - Drop zone

    private var dropZoneEnabled: Bool {
        settings.moduleBool(id: info.id, key: Key.dropZone) ?? false
    }

    // The settings pane calls this instead of writing the setting directly,
    // so a live toggle immediately reaches the shared drop-zone coordinator.
    func setDropZoneEnabled(_ on: Bool) {
        settings.setModuleBool(on, id: info.id, key: Key.dropZone)
        if active { dropZoneCoordinator.setConvertActive(on) }
    }

    // MARK: - Triggers

    // Reads the current Finder selection via Apple Events (first use prompts
    // for Automation consent), same trick Clop uses.
    func convertFinderSelection() {
        Log.info("convert: convert Finder selection requested")
        guard let script = NSAppleScript(
            source: "tell application \"Finder\" to return selection as alias list") else { return }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            Log.error("convert: Finder selection read failed: \(errorInfo)")
            ConvertToast.show("Allow FreeKit to control Finder in Privacy & Security > Automation")
            return
        }
        var urls: [URL] = []
        let descriptors = result.descriptorType == typeAEList
            ? (1...max(1, result.numberOfItems)).compactMap { result.atIndex($0) }
            : [result]
        for descriptor in descriptors {
            if let data = descriptor.coerce(toDescriptorType: typeFileURL)?.data,
               let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                urls.append(url)
            }
        }
        let supported = urls.filter { ConvertPlan.mediaKind(forFileExtension: $0.pathExtension) != nil }
        guard !supported.isEmpty else {
            ConvertToast.show("No convertible files selected in Finder")
            return
        }
        convertFiles(supported)
    }

    // Only a single file URL on the clipboard is handled (matching Clop's
    // ambiguity rule for multi-file copies); raw image/media bytes are not,
    // since there is no source file to write the result alongside or replace.
    func convertClipboardNow() {
        Log.info("convert: convert clipboard now requested")
        let pasteboard = NSPasteboard.general
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            urls.count == 1, let url = urls.first,
            ConvertPlan.mediaKind(forFileExtension: url.pathExtension) != nil else {
            ConvertToast.show("No convertible file on the clipboard")
            return
        }
        convertFiles([url])
    }

    func convertFilesFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images, audio, video, PDFs, or documents to convert"
        panel.prompt = "Convert"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let self, !panel.urls.isEmpty else { return }
            self.convertFiles(panel.urls)
        }
    }

    // MARK: - Undo

    func undoLastConversion() {
        guard let undo = lastUndo else { return }
        lastUndo = nil
        do {
            // Restore via a staging copy so the backup survives as a second
            // safety net even after a successful undo.
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("convert-undo-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: undo.backup, to: staging)
            if FileManager.default.fileExists(atPath: undo.original.path) {
                _ = try FileManager.default.replaceItemAt(undo.original, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: undo.original)
            }
            if let replacement = undo.replacement, replacement != undo.original {
                try? FileManager.default.removeItem(at: replacement)
            }
            Log.info("convert: restored \(undo.original.path) from backup \(undo.backup.path)")
            finish(result: "Restored \(undo.original.lastPathComponent)")
        } catch {
            Log.error("convert: undo failed for \(undo.original.path) from \(undo.backup.path): \(error.localizedDescription)")
            finish(result: "Undo failed \u{2014} backup kept in convert-backups")
        }
    }

    // MARK: - Conversion

    // `forcedTarget` comes from a specific "Convert to X" Finder service; nil
    // means the caller (menu bar, Finder selection, open panel, drop zone,
    // clipboard) takes the plan as Settings has it configured.
    // Used by the "Convert to X" Finder services: everything but `kind` stays
    // at whatever the user has configured.
    func convertFiles(_ urls: [URL], overridingKind kind: ConvertPlan.MediaKind, rawValue: String) {
        guard let target = ConvertPlan.Target.overriding(
            kind: kind, rawValue: rawValue, base: Self.currentTarget(settings: settings)) else {
            Log.error("convert: convert-to-format got unrecognized format \(rawValue) for kind \(kind.rawValue)")
            return
        }
        convertFiles(urls, forcedTarget: target)
    }

    // `imageQuality` is the App tab's per-operation quality knob (JPEG/HEIC
    // compression, JPEG-rasterized PDF pages); nil keeps ConvertEngine's
    // default. It has no persisted setting of its own — Convert's defaults
    // (Tool tab) don't model quality at all, only format.
    func convertFiles(_ urls: [URL], forcedTarget: ConvertPlan.Target? = nil, imageQuality: Double? = nil) {
        let target = forcedTarget ?? Self.currentTarget(settings: settings)
        Log.info("convert: converting \(urls.count) file(s), destination=\(target.destination.rawValue)")
        runTracked { [self] in
            beginWork()
            var convertedCount = 0
            var skipped = 0
            var cancelled = false
            for (index, url) in urls.enumerated() {
                if Task.isCancelled {
                    skipped += urls.count - index
                    cancelled = true
                    Log.info("convert: batch cancelled after \(index) of \(urls.count) file(s)")
                    break
                }
                batchProgress = (index, urls.count)
                updateStatusIcon()
                do {
                    if try await convertFile(url, target: target, imageQuality: imageQuality) {
                        convertedCount += 1
                    } else {
                        skipped += 1
                    }
                } catch is CancellationError {
                    skipped += urls.count - index
                    cancelled = true
                    Log.info("convert: batch cancelled during \(url.lastPathComponent)")
                    break
                } catch {
                    skipped += 1
                    Log.error("convert: failed for \(url.path): \(error.localizedDescription)")
                }
            }
            endWork()
            if convertedCount > 0 {
                recordConversions(convertedCount)
            }
            let summary: String
            if cancelled {
                summary = "Cancelled \u{2014} \(convertedCount) file\(convertedCount == 1 ? "" : "s") done first"
            } else if convertedCount > 0 {
                summary = "Converted \(convertedCount) file\(convertedCount == 1 ? "" : "s")"
                    + (skipped > 0 ? ", \(skipped) skipped" : "")
            } else {
                summary = "Nothing to convert \u{2014} already in the target format, or unsupported"
            }
            Log.info("convert: batch done \u{2014} \(convertedCount) converted, \(skipped) skipped")
            finish(result: summary)
        }
    }

    // Returns false when the file was skipped (unsupported type, or already
    // sitting in the target format). Video always re-encodes even when the
    // extension already matches: "mp4" covers both H.264 and HEVC, so an
    // extension match alone cannot tell whether the codec already matches.
    private func convertFile(_ url: URL, target: ConvertPlan.Target, imageQuality: Double? = nil) async throws -> Bool {
        guard let kind = ConvertPlan.mediaKind(forFileExtension: url.pathExtension),
              let targetExt = target.outputExtension(forSourceExtension: url.pathExtension) else {
            Log.info("convert: skipped \(url.lastPathComponent): unsupported type")
            return false
        }
        if kind != .video,
           !ConvertPlan.needsConversion(currentExtension: url.pathExtension, targetExtension: targetExt) {
            Log.info("convert: skipped \(url.lastPathComponent): already .\(targetExt)")
            return false
        }
        switch kind {
        case .image:
            let format = target.image
            let data = try await Task.detached(priority: .userInitiated) {
                try ConvertEngine.convertImage(at: url, to: format, quality: imageQuality ?? 0.92)
            }.value
            try writeDataResult(data, for: url, targetExtension: targetExt, destination: target.destination)
        case .audio:
            let tempURL = Self.tempOutputURL(extension: targetExt)
            try await ConvertEngine.convertAudio(at: url, to: target.audio, outputURL: tempURL)
            try moveFileResult(from: tempURL, for: url, targetExtension: targetExt, destination: target.destination)
        case .video:
            let tempURL = Self.tempOutputURL(extension: targetExt)
            try await ConvertEngine.convertVideo(
                at: url, to: target.video, outputURL: tempURL) { [weak self] fraction in
                self?.videoProgress = fraction
                self?.updateStatusIcon()
            }
            try moveFileResult(from: tempURL, for: url, targetExtension: targetExt, destination: target.destination)
        case .document:
            let format = target.document
            let result = try await Task.detached(priority: .userInitiated) {
                try ConvertEngine.convertDocument(at: url, to: format)
            }.value
            switch result {
            case .data(let data):
                try writeDataResult(data, for: url, targetExtension: targetExt, destination: target.destination)
            case .fileWrapper(let wrapper):
                try writeFileWrapperResult(wrapper, for: url, targetExtension: targetExt, destination: target.destination)
            }
        case .pdf:
            let pdfTarget = target.pdf
            let data: Data
            switch pdfTarget {
            case .png, .jpeg:
                data = try await Task.detached(priority: .userInitiated) {
                    try ConvertEngine.rasterizeFirstPage(at: url, format: pdfTarget, quality: imageQuality ?? 0.92)
                }.value
            case .plainText:
                let text = try await Task.detached(priority: .userInitiated) {
                    try ConvertEngine.extractText(at: url)
                }.value
                data = Data(text.utf8)
            }
            try writeDataResult(data, for: url, targetExtension: targetExt, destination: target.destination)
        }
        return true
    }

    // MARK: - Split / combine (App tab only — one-to-many and many-to-one
    // shapes that don't fit convertFiles' one-target-per-file model)

    // One JPEG per page, written alongside the source PDF. `.replace` backs
    // the PDF up and removes it once every page has been written — there is
    // no single 1:1 file to rename in place the way a normal conversion does.
    func splitPDF(_ url: URL, quality: Double, destination: ConvertPlan.FileDestination) {
        Log.info("convert: splitting \(url.lastPathComponent), destination=\(destination.rawValue)")
        runTracked { [self] in
            beginWork()
            do {
                let pages = try await Task.detached(priority: .userInitiated) {
                    try ConvertEngine.rasterizeAllPages(at: url, quality: quality)
                }.value
                for (index, data) in pages.enumerated() {
                    let pageURL = ConvertPlan.pageNumberedURL(
                        for: url, page: index + 1, targetExtension: "jpg") {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                    try data.write(to: pageURL, options: .atomic)
                    Log.info("convert: wrote \(pageURL.path)")
                }
                if destination == .replace {
                    let backup = try backUp(url)
                    try FileManager.default.removeItem(at: url)
                    Log.info("convert: removed \(url.path) after split, backup at \(backup.path)")
                }
                endWork()
                recordConversions(1)
                finish(result: "Split into \(pages.count) page image\(pages.count == 1 ? "" : "s")")
            } catch {
                endWork()
                Log.error("convert: split failed for \(url.path): \(error.localizedDescription)")
                finish(result: "Could not split \(url.lastPathComponent)")
            }
        }
    }

    // All source images combined, in order, into one new PDF written
    // alongside the first image. `.replace` backs each source up and removes
    // it afterward — again there is no single 1:1 file to rename in place.
    func combineImages(_ urls: [URL], destination: ConvertPlan.FileDestination) {
        guard let first = urls.first else { return }
        Log.info("convert: combining \(urls.count) image(s), destination=\(destination.rawValue)")
        runTracked { [self] in
            beginWork()
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try ConvertEngine.combineImagesToPDF(urls)
                }.value
                let combinedURL = ConvertPlan.combinedPDFURL(
                    baseName: "Combined", in: first.deletingLastPathComponent()) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                try data.write(to: combinedURL, options: .atomic)
                Log.info("convert: wrote \(combinedURL.path)")
                if destination == .replace {
                    for source in urls {
                        let backup = try backUp(source)
                        try FileManager.default.removeItem(at: source)
                        Log.info("convert: removed \(source.path) after combine, backup at \(backup.path)")
                    }
                }
                endWork()
                recordConversions(1)
                finish(result: "Combined \(urls.count) image\(urls.count == 1 ? "" : "s") into \(combinedURL.lastPathComponent)")
            } catch {
                endWork()
                Log.error("convert: combine failed: \(error.localizedDescription)")
                finish(result: "Could not combine images")
            }
        }
    }

    private static func tempOutputURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("convert-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    private func writeDataResult(_ data: Data, for original: URL, targetExtension: String,
                                 destination: ConvertPlan.FileDestination) throws {
        switch destination {
        case .alongside:
            let sibling = ConvertPlan.siblingURL(for: original, targetExtension: targetExtension) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            try data.write(to: sibling, options: .atomic)
            Log.info("convert: wrote \(sibling.path)")
        case .replace:
            let backup = try backUp(original)
            if original.pathExtension.lowercased() == targetExtension.lowercased() {
                try data.write(to: original, options: .atomic)
                lastUndo = FileUndo(original: original, backup: backup, replacement: nil)
                Log.info("convert: replaced \(original.path), backup at \(backup.path)")
            } else {
                let renamed = ConvertPlan.replacementURL(for: original, targetExtension: targetExtension) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                try data.write(to: renamed, options: .atomic)
                try FileManager.default.removeItem(at: original)
                lastUndo = FileUndo(original: original, backup: backup, replacement: renamed)
                Log.info("convert: replaced \(original.path) with \(renamed.lastPathComponent), backup at \(backup.path)")
            }
        }
    }

    // RTFD is a directory package: FileWrapper writes it as a bundle rather
    // than a single data blob (see ConvertEngine.convertDocument).
    private func writeFileWrapperResult(_ wrapper: FileWrapper, for original: URL, targetExtension: String,
                                        destination: ConvertPlan.FileDestination) throws {
        switch destination {
        case .alongside:
            let sibling = ConvertPlan.siblingURL(for: original, targetExtension: targetExtension) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            try wrapper.write(to: sibling, options: .atomic, originalContentsURL: nil)
            Log.info("convert: wrote \(sibling.path)")
        case .replace:
            let backup = try backUp(original)
            if original.pathExtension.lowercased() == targetExtension.lowercased() {
                try? FileManager.default.removeItem(at: original)
                try wrapper.write(to: original, options: .atomic, originalContentsURL: nil)
                lastUndo = FileUndo(original: original, backup: backup, replacement: nil)
                Log.info("convert: replaced \(original.path), backup at \(backup.path)")
            } else {
                let renamed = ConvertPlan.replacementURL(for: original, targetExtension: targetExtension) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                try wrapper.write(to: renamed, options: .atomic, originalContentsURL: nil)
                try FileManager.default.removeItem(at: original)
                lastUndo = FileUndo(original: original, backup: backup, replacement: renamed)
                Log.info("convert: replaced \(original.path) with \(renamed.lastPathComponent), backup at \(backup.path)")
            }
        }
    }

    private func moveFileResult(from temp: URL, for original: URL, targetExtension: String,
                                destination: ConvertPlan.FileDestination) throws {
        switch destination {
        case .alongside:
            let sibling = ConvertPlan.siblingURL(for: original, targetExtension: targetExtension) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            try FileManager.default.moveItem(at: temp, to: sibling)
            Log.info("convert: wrote \(sibling.path)")
        case .replace:
            let backup = try backUp(original)
            if original.pathExtension.lowercased() == targetExtension.lowercased() {
                _ = try FileManager.default.replaceItemAt(original, withItemAt: temp)
                lastUndo = FileUndo(original: original, backup: backup, replacement: nil)
                Log.info("convert: replaced \(original.path), backup at \(backup.path)")
            } else {
                let renamed = ConvertPlan.replacementURL(for: original, targetExtension: targetExtension) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                try FileManager.default.moveItem(at: temp, to: renamed)
                try FileManager.default.removeItem(at: original)
                lastUndo = FileUndo(original: original, backup: backup, replacement: renamed)
                Log.info("convert: replaced \(original.path) with \(renamed.lastPathComponent), backup at \(backup.path)")
            }
        }
    }

    private func backUp(_ url: URL) throws -> URL {
        let directory = Self.backupsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = ConvertPlan.backupURL(for: url, in: directory) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    func revealBackupsFolder() {
        let directory = Self.backupsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
        Log.info("convert: opened backups folder \(directory.path)")
    }

    // MARK: - Work tracking

    private func runTracked(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        runningTasks[id] = Task { @MainActor in
            await operation()
            runningTasks[id] = nil
        }
    }

    func cancelAllWork() {
        guard !runningTasks.isEmpty else { return }
        Log.info("convert: cancelling \(runningTasks.count) running task(s)")
        for task in runningTasks.values { task.cancel() }
    }

    private func recordConversions(_ count: Int) {
        let total = (settings.moduleInt(id: info.id, key: Key.totalItems) ?? 0) + count
        settings.setModuleInt(total, id: info.id, key: Key.totalItems)
    }

    // MARK: - Status item

    private func beginWork() {
        working += 1
        paneModel.working = true
        updateStatusIcon()
    }

    private func endWork() {
        working = max(0, working - 1)
        if working == 0 {
            videoProgress = nil
            batchProgress = nil
            paneModel.working = false
        }
        updateStatusIcon()
    }

    private func finish(result: String) {
        lastResult = result
        updateStatusIcon()
        if settings.moduleBool(id: info.id, key: Key.toast) ?? true {
            let duration = settings.moduleDouble(id: info.id, key: Key.toastDuration) ?? 2.6
            let location = settings.moduleString(id: info.id, key: Key.toastLocation)
                .flatMap(ConvertToastLocation.init) ?? .bottomCenter
            ConvertToast.show(result, duration: duration, location: location)
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let state: IconState = working > 0 ? .working : .idle
        if state != lastIconState, lastIconState != nil, !DS.reduceMotion, let layer = button.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = DS.hudCrossfade
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "iconState")
        }
        lastIconState = state
        button.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: working > 0 ? "Convert working" : "Convert idle")
        button.contentTintColor = working > 0 ? DS.accent : nil
        let progressText: String
        if working > 0, let batch = batchProgress {
            progressText = " \(batch.done + 1)/\(batch.total)"
        } else if working > 0, let videoProgress {
            progressText = String(format: " %.0f%%", videoProgress * 100)
        } else {
            progressText = ""
        }
        button.attributedTitle = NSAttributedString(
            string: progressText,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
        button.toolTip = working > 0 ? "Convert: working" : "Convert: drop files here"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let statusTitle: String
        if working > 0, let batch = batchProgress {
            statusTitle = "Converting \(batch.done + 1) of \(batch.total)\u{2026}"
        } else if working > 0 {
            statusTitle = videoProgress.map { String(format: "Converting video \u{2014} %.0f%%", $0 * 100) }
                ?? "Converting\u{2026}"
        } else {
            statusTitle = "Ready \u{2014} drop files here"
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let lastResult {
            let last = NSMenuItem(title: lastResult, action: nil, keyEquivalent: "")
            last.isEnabled = false
            menu.addItem(last)
        }
        let totalItems = settings.moduleInt(id: info.id, key: Key.totalItems) ?? 0
        if totalItems > 0 {
            let total = NSMenuItem(
                title: "Converted \(totalItems) file\(totalItems == 1 ? "" : "s") total",
                action: nil, keyEquivalent: "")
            total.isEnabled = false
            menu.addItem(total)
        }
        menu.addItem(.separator())
        if working > 0 {
            let cancel = NSMenuItem(
                title: "Cancel Conversion", action: #selector(menuCancelWork), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }
        let hotkeySuffix = hotkey.keyCode == HotkeyPreset.disabled.keyCode
            ? "" : " (\(hotkey.displayName))"
        let now = NSMenuItem(
            title: "Convert Clipboard Now\(hotkeySuffix)",
            action: #selector(menuConvertClipboard), keyEquivalent: "")
        now.target = self
        menu.addItem(now)
        let files = NSMenuItem(
            title: "Convert Files\u{2026}", action: #selector(menuConvertFiles), keyEquivalent: "")
        files.target = self
        menu.addItem(files)
        let undo = NSMenuItem(
            title: "Undo Last Conversion", action: #selector(menuUndo), keyEquivalent: "")
        undo.target = self
        undo.isEnabled = lastUndo != nil
        menu.addItem(undo)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Convert Settings\u{2026}", action: #selector(menuOpenSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    @objc private func menuConvertClipboard() {
        convertClipboardNow()
    }

    @objc private func menuConvertFiles() {
        convertFilesFromPanel()
    }

    @objc private func menuUndo() {
        undoLastConversion()
    }

    @objc private func menuCancelWork() {
        cancelAllWork()
    }

    @objc private func menuOpenSettings() {
        openSettings()
    }
}

// Transparent overlay on the status-item button that accepts file drags,
// mirroring Clop's ClopDropView: it stays hit-testable so mouse clicks still
// reach the button underneath and the menu keeps working.
private final class ConvertDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func mouseDown(with event: NSEvent) {
        (superview as? NSControl)?.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        (superview as? NSControl)?.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        (superview as? NSControl)?.otherMouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        supportedURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = supportedURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func supportedURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ConvertPlan.mediaKind(forFileExtension: $0.pathExtension) != nil }
    }
}

// MARK: - Settings pane

final class ConvertPaneModel: ObservableObject {
    weak var module: ConvertModule?
    // Lets the App tab disable Save/Replace mid-conversion without new
    // plumbing — mirrors ConvertModule's own `working` counter.
    @Published var working = false
}

// Tool tab: the persisted defaults background triggers (hotkey, Finder,
// clipboard, drop-zone) use. Interactive per-file conversion lives in the
// App tab (ConvertAppTabView, ConvertAppTab.swift) instead.
struct ConvertToolTabView: View {
    @ObservedObject var model: ConvertPaneModel
    let settings: Settings

    private let moduleID = ModuleCatalog.convert.id
    @State private var imageFormat: ConvertPlan.ImageFormat
    @State private var audioFormat: ConvertPlan.AudioFormat
    @State private var videoFormat: ConvertPlan.VideoFormat
    @State private var documentFormat: ConvertPlan.DocumentFormat
    @State private var pdfFormat: ConvertPlan.PDFTarget
    @State private var destination: ConvertPlan.FileDestination
    @State private var dropZoneOn: Bool
    @State private var showToast: Bool
    @State private var toastDuration: Double
    @State private var toastLocation: ConvertToastLocation
    @ObservedObject var registry: ModuleRegistry

    init(model: ConvertPaneModel, settings: Settings, registry: ModuleRegistry) {
        self.model = model
        self.settings = settings
        self.registry = registry
        let id = ModuleCatalog.convert.id
        _imageFormat = State(initialValue: settings.moduleString(id: id, key: ConvertModule.Key.imageFormat)
            .flatMap(ConvertPlan.ImageFormat.init) ?? .jpeg)
        _audioFormat = State(initialValue: settings.moduleString(id: id, key: ConvertModule.Key.audioFormat)
            .flatMap(ConvertPlan.AudioFormat.init) ?? .m4a)
        _videoFormat = State(initialValue: settings.moduleString(id: id, key: ConvertModule.Key.videoFormat)
            .flatMap(ConvertPlan.VideoFormat.init) ?? .mp4HEVC)
        _documentFormat = State(initialValue: settings.moduleString(id: id, key: ConvertModule.Key.documentFormat)
            .flatMap(ConvertPlan.DocumentFormat.init) ?? .pdf)
        _pdfFormat = State(initialValue: settings.moduleString(id: id, key: ConvertModule.Key.pdfFormat)
            .flatMap(ConvertPlan.PDFTarget.init) ?? .png)
        _destination = State(initialValue: settings.moduleString(id: id, key: ConvertModule.Key.destination)
            .flatMap(ConvertPlan.FileDestination.init) ?? .alongside)
        _dropZoneOn = State(initialValue: settings.moduleBool(id: id, key: ConvertModule.Key.dropZone) ?? false)
        _showToast = State(initialValue: settings.moduleBool(id: id, key: ConvertModule.Key.toast) ?? true)
        _toastDuration = State(initialValue: settings.moduleDouble(id: id, key: ConvertModule.Key.toastDuration) ?? 2.6)
        _toastLocation = State(initialValue: settings.moduleString(id: id, key: ConvertModule.Key.toastLocation)
            .flatMap(ConvertToastLocation.init) ?? .bottomCenter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSettingsCard(title: "Images") {
                optionRow("Target") {
                    ForEach(ConvertPlan.ImageFormat.allCases, id: \.rawValue) { value in
                        chip(value.displayName, selected: imageFormat == value) {
                            imageFormat = value
                            settings.setModuleString(value.rawValue, id: moduleID, key: ConvertModule.Key.imageFormat)
                        }
                    }
                }
                Text("Animated images (multi-frame GIFs) are left untouched: flattening to one frame would destroy the animation.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }

            DSSettingsCard(title: "Audio") {
                optionRow("Target") {
                    ForEach(ConvertPlan.AudioFormat.allCases, id: \.rawValue) { value in
                        chip(value.displayName, selected: audioFormat == value) {
                            audioFormat = value
                            settings.setModuleString(value.rawValue, id: moduleID, key: ConvertModule.Key.audioFormat)
                        }
                    }
                }
            }

            DSSettingsCard(title: "Video") {
                optionRow("Target") {
                    ForEach(ConvertPlan.VideoFormat.allCases, id: \.rawValue) { value in
                        chip(value.displayName, selected: videoFormat == value) {
                            videoFormat = value
                            settings.setModuleString(value.rawValue, id: moduleID, key: ConvertModule.Key.videoFormat)
                        }
                    }
                }
            }

            DSSettingsCard(title: "Documents") {
                optionRow("Target") {
                    ForEach(ConvertPlan.DocumentFormat.allCases, id: \.rawValue) { value in
                        chip(value.displayName, selected: documentFormat == value) {
                            documentFormat = value
                            settings.setModuleString(value.rawValue, id: moduleID, key: ConvertModule.Key.documentFormat)
                        }
                    }
                }
                Text("Covers RTF, RTFD, Word (.doc/.docx), HTML, plain text, and OpenDocument Text. PDF renders the text through a headless print pass, so the result is no longer editable.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }

            DSSettingsCard(title: "PDF source") {
                optionRow("Target") {
                    ForEach(ConvertPlan.PDFTarget.allCases, id: \.rawValue) { value in
                        chip(value.displayName, selected: pdfFormat == value) {
                            pdfFormat = value
                            settings.setModuleString(value.rawValue, id: moduleID, key: ConvertModule.Key.pdfFormat)
                        }
                    }
                }
                Text("Image targets only rasterize the first page; Plain Text extracts every page.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }

            DSSettingsCard(title: "Files") {
                optionRow("Output") {
                    ForEach(ConvertPlan.FileDestination.allCases, id: \.rawValue) { value in
                        chip(value.displayName, selected: destination == value) {
                            destination = value
                            settings.setModuleString(value.rawValue, id: moduleID, key: ConvertModule.Key.destination)
                        }
                    }
                }
                DSToggleRow(
                    title: "Drop zone while dragging",
                    caption: "A floating catcher appears at the bottom of the screen while you drag. If Clop's drop zone is also on, the catcher splits so you can choose either one.",
                    isOn: Binding(
                        get: { dropZoneOn },
                        set: {
                            dropZoneOn = $0
                            model.module?.setDropZoneEnabled($0)
                        }))
                Text("Alongside writes \u{201C}name (converted)\u{201D} next to the original. Replace backs the original up first, then renames honestly: shot.png becomes shot.jpg. Files can also be dropped onto the menu bar icon.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
                Button("Show Backup Folder") { model.module?.revealBackupsFolder() }
                    .buttonStyle(GhostButtonStyle())
            }

            DSSettingsCard(title: "Result toast") {
                DSToggleRow(
                    title: "Show result toast",
                    caption: "A brief floating readout of every outcome, including skips.",
                    isOn: Binding(
                        get: { showToast },
                        set: {
                            showToast = $0
                            settings.setModuleBool($0, id: moduleID, key: ConvertModule.Key.toast)
                        }))
                if showToast {
                    optionRow("Time on screen") {
                        DSNumberField(
                            placeholder: "sec", value: $toastDuration,
                            range: 0.5...15, fractionDigits: 1,
                            onCommit: { settings.setModuleDouble($0, id: moduleID, key: ConvertModule.Key.toastDuration) })
                        Text("seconds before the toast fades")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsFaint)
                    }
                    optionRow("Location") {
                        chip("Bottom", selected: toastLocation.isBottom) {
                            setToastLocation(.make(bottom: true, align: toastLocation.align))
                        }
                        chip("Top", selected: !toastLocation.isBottom) {
                            setToastLocation(.make(bottom: false, align: toastLocation.align))
                        }
                    }
                    optionRow("Align") {
                        ForEach(ConvertToastLocation.Align.allCases, id: \.self) { value in
                            chip(value.title, selected: toastLocation.align == value) {
                                setToastLocation(.make(bottom: toastLocation.isBottom, align: value))
                            }
                        }
                    }
                }
            }

            DSSettingsCard(title: "Control") {
                // Convert's Apps-tab card skips the usual ON toggle column in
                // favor of a one-click Open; this row is where that control
                // lives instead. There is no menu-bar-visibility toggle: the
                // status item just self-manages, showing whenever Convert is on.
                DSToggleRow(
                    title: "Enabled",
                    caption: "Turns off hotkeys, Finder services, the menu bar icon, and the floating drop zone.",
                    isOn: Binding(
                        get: { registry.isEnabled(id: moduleID) },
                        set: { registry.setEnabled($0, id: moduleID) }))
                HotkeyRecorderButton(
                    label: "Convert clipboard",
                    preset: settings.moduleHotkey(id: moduleID, defaultPreset: .disabled),
                    onChange: { model.module?.updateHotkey($0) })
                HotkeyRecorderButton(
                    label: "Convert Finder selection",
                    preset: model.module?.finderHotkey ?? .disabled,
                    onChange: { model.module?.updateFinderHotkey($0) })
                Text("The Finder shortcut reads the current selection (macOS asks once to allow controlling Finder). Right-clicking files also offers Services > Convert with FreeKit, plus a Convert to X entry for every format.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }
        }
    }

    private func setToastLocation(_ location: ConvertToastLocation) {
        toastLocation = location
        settings.setModuleString(location.rawValue, id: moduleID, key: ConvertModule.Key.toastLocation)
    }

    private func optionRow<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color.dsFaint)
                .frame(width: 80, alignment: .leading)
            content()
            Spacer()
        }
    }
}

private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    DSChip(title: title, selected: selected, action: action)
        .fixedSize()
}
