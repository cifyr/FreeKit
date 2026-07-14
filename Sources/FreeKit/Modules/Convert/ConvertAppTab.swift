import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FreeKitCore

// Convert's settings popup: a thin App/Tool tab switcher, same DSTabButton
// row pattern SettingsWindow.swift and ControlCenterWindow.swift already use
// for their own tabs (not SwiftUI's native TabView, to stay visually
// consistent with the rest of the suite).
struct ConvertSettingsPane: View {
    @ObservedObject var model: ConvertPaneModel
    let settings: Settings
    let registry: ModuleRegistry
    @State private var tab: InitialTab

    // Which tab to land on when the popup opens: Convert's Apps-tab "Open"
    // reads as launching the app, so it lands on App; its Tools-tab proxy
    // card reads as configuring the tool, so it lands on Tool instead.
    enum InitialTab: String, CaseIterable {
        case app = "App", tool = "Tool"
    }

    init(model: ConvertPaneModel, settings: Settings, registry: ModuleRegistry, initialTab: InitialTab = .app) {
        self.model = model
        self.settings = settings
        self.registry = registry
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabRow
            switch tab {
            case .app: ConvertAppTabView(model: model, settings: settings)
            case .tool: ConvertToolTabView(model: model, settings: settings, registry: registry)
            }
        }
    }

    private var tabRow: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(Color.dsLine).frame(height: 1)
            HStack(spacing: 24) {
                ForEach(InitialTab.allCases, id: \.self) { candidate in
                    DSTabButton(title: candidate.rawValue, selected: tab == candidate) {
                        tab = candidate
                    }
                }
                Spacer()
            }
        }
    }
}

// App tab: drop one or more files, pick a format (and quality, where
// relevant) per file type present, then Save (alongside) or Replace
// Original — the interactive iLovePDF/CloudConvert-style converter. The Tool
// tab's persisted defaults seed each format picker's initial selection but
// nothing here is saved; it is a fresh choice every time.
struct ConvertAppTabView: View {
    @ObservedObject var model: ConvertPaneModel
    let settings: Settings

    @State private var droppedURLs: [URL] = []
    @State private var isTargeted = false
    @State private var selectedFormat: [ConvertPlan.MediaKind: String] = [:]
    @State private var specialOperation: SpecialOperation?
    @State private var quality: Double = 0.85

    private enum SpecialOperation: Equatable {
        case splitPDF, combineImages
    }

    private struct DroppedGroup: Identifiable {
        let kind: ConvertPlan.MediaKind
        let urls: [URL]
        var id: String { kind.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropCard
            ForEach(groups) { group in
                groupCard(group)
            }
            if !groups.isEmpty {
                if showsQuality { qualityCard }
                actionButtons
            }
        }
    }

    // MARK: - Dropped-file grouping

    // Stable kind order (MediaKind.allCases), not drop order — deterministic
    // regardless of which file in a mixed drop landed first.
    private var groups: [DroppedGroup] {
        let recognized = droppedURLs.filter { ConvertPlan.mediaKind(forFileExtension: $0.pathExtension) != nil }
        let byKind = Dictionary(grouping: recognized) { ConvertPlan.mediaKind(forFileExtension: $0.pathExtension)! }
        return ConvertPlan.MediaKind.allCases.compactMap { kind in
            byKind[kind].map { DroppedGroup(kind: kind, urls: $0) }
        }
    }

    private var canSplitPDF: Bool {
        groups.count == 1 && groups[0].kind == .pdf && groups[0].urls.count == 1
    }

    private var canCombineImages: Bool {
        groups.count == 1 && groups[0].kind == .image && groups[0].urls.count >= 2
    }

    // MARK: - Views

    private var dropCard: some View {
        DSSettingsCard(title: "Convert") {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isTargeted ? Color.dsAccent : Color.dsMuted)
                Text(droppedURLs.isEmpty ? "Drop files here to convert"
                     : "\(droppedURLs.count) file\(droppedURLs.count == 1 ? "" : "s") ready")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dsPaper)
                Text("Pick a format below, then Save or Replace Original")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsFaint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.dsInk2.opacity(0.4)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Color.dsAccent : Color.dsLine,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .animation(DS.animBase, value: isTargeted)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
        }
    }

    private func groupCard(_ group: DroppedGroup) -> some View {
        DSSettingsCard(title: group.urls.count > 1 ? "\(title(for: group.kind)) (\(group.urls.count))" : title(for: group.kind)) {
            Text(group.urls.map(\.lastPathComponent).joined(separator: ", "))
                .font(.system(size: 11))
                .foregroundStyle(Color.dsMuted)
                .lineLimit(2)
            optionRow("Format") {
                ForEach(formatOptions(for: group.kind), id: \.rawValue) { option in
                    chip(option.displayName, selected: specialOperation == nil && selection(for: group.kind) == option.rawValue) {
                        specialOperation = nil
                        selectedFormat[group.kind] = option.rawValue
                    }
                }
                if group.kind == .pdf, canSplitPDF {
                    chip("Split into JPEGs (all pages)", selected: specialOperation == .splitPDF) {
                        specialOperation = .splitPDF
                    }
                }
                if group.kind == .image, canCombineImages {
                    chip("Combine into one PDF", selected: specialOperation == .combineImages) {
                        specialOperation = .combineImages
                    }
                }
            }
        }
    }

    private var qualityCard: some View {
        DSSettingsCard(title: "Quality") {
            optionRow("Quality") {
                ForEach([(0.5, "Small"), (0.75, "Balanced"), (0.9, "High")], id: \.0) { value, label in
                    chip(label, selected: abs(quality - value) < 0.0001) { quality = value }
                }
                DSNumberField(placeholder: "0\u{2013}1", value: $quality, range: 0.1...1.0, fractionDigits: 2,
                             onCommit: { quality = $0 })
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button("Save") { run(destination: .alongside) }
                .buttonStyle(GhostButtonStyle())
            Button("Replace Original") { run(destination: .replace) }
                .buttonStyle(PrimaryButtonStyle())
            Spacer()
        }
        .disabled(model.working)
    }

    // MARK: - Actions

    private func run(destination: ConvertPlan.FileDestination) {
        guard let module = model.module else { return }
        if specialOperation == .splitPDF, let url = groups.first(where: { $0.kind == .pdf })?.urls.first {
            module.splitPDF(url, quality: quality, destination: destination)
            return
        }
        if specialOperation == .combineImages, let group = groups.first(where: { $0.kind == .image }) {
            module.combineImages(group.urls, destination: destination)
            return
        }
        let base = ConvertModule.currentTarget(settings: settings)
        for group in groups {
            guard var target = ConvertPlan.Target.overriding(
                kind: group.kind, rawValue: selection(for: group.kind), base: base) else { continue }
            target.destination = destination
            module.convertFiles(group.urls, forcedTarget: target, imageQuality: quality)
        }
    }

    // NSItemProvider loads run off-main and can complete on arbitrary
    // threads; the lock guards `urls` until every provider has reported in.
    // A fresh drop replaces whatever was dropped before, rather than
    // accumulating across separate drag gestures.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let lock = NSLock()
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      ConvertPlan.mediaKind(forFileExtension: url.pathExtension) != nil else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            droppedURLs = urls
            specialOperation = nil
            selectedFormat = [:]
        }
        return true
    }

    // MARK: - Format helpers

    private func title(for kind: ConvertPlan.MediaKind) -> String {
        switch kind {
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .document: return "Document"
        case .pdf: return "PDF"
        }
    }

    private func formatOptions(for kind: ConvertPlan.MediaKind) -> [(rawValue: String, displayName: String)] {
        switch kind {
        case .image: return ConvertPlan.ImageFormat.allCases.map { ($0.rawValue, $0.displayName) }
        case .audio: return ConvertPlan.AudioFormat.allCases.map { ($0.rawValue, $0.displayName) }
        case .video: return ConvertPlan.VideoFormat.allCases.map { ($0.rawValue, $0.displayName) }
        case .document: return ConvertPlan.DocumentFormat.allCases.map { ($0.rawValue, $0.displayName) }
        case .pdf: return ConvertPlan.PDFTarget.allCases.map { ($0.rawValue, $0.displayName) }
        }
    }

    // Falls back to the Tool tab's persisted default so a picker starts
    // sensibly populated instead of blank.
    private func defaultRawValue(for kind: ConvertPlan.MediaKind) -> String {
        let target = ConvertModule.currentTarget(settings: settings)
        switch kind {
        case .image: return target.image.rawValue
        case .audio: return target.audio.rawValue
        case .video: return target.video.rawValue
        case .document: return target.document.rawValue
        case .pdf: return target.pdf.rawValue
        }
    }

    private func selection(for kind: ConvertPlan.MediaKind) -> String {
        selectedFormat[kind] ?? defaultRawValue(for: kind)
    }

    private var showsQuality: Bool {
        if specialOperation == .splitPDF { return true }
        if specialOperation == .combineImages { return false }
        for group in groups {
            let raw = selection(for: group.kind)
            if group.kind == .image,
               raw == ConvertPlan.ImageFormat.jpeg.rawValue || raw == ConvertPlan.ImageFormat.heic.rawValue {
                return true
            }
            if group.kind == .pdf, raw == ConvertPlan.PDFTarget.jpeg.rawValue {
                return true
            }
        }
        return false
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
