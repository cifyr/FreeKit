import AppKit
import Combine
import Darwin
import SwiftUI
import FreeSpeechCore

final class AppCleanerModule: NSObject, AppModule {
    let info = ModuleCatalog.appCleaner
    private let config: AppCleanerConfig
    private let model: AppCleanerViewModel
    private var statusItem: NSStatusItem?
    private lazy var settingsWindow = ModuleSettingsWindowController(
        info: info,
        contentSize: NSSize(width: 820, height: 650),
        minimumSize: NSSize(width: 680, height: 480)
    ) { [config, model] in
        AnyView(AppCleanerView(model: model, config: config))
    }

    init(settings: Settings) {
        config = AppCleanerConfig(settings: settings)
        model = AppCleanerViewModel()
        super.init()
    }

    func activate() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                button.image = NSImage(systemSymbolName: info.symbolName,
                                       accessibilityDescription: "Open AppCleaner")
                button.toolTip = "AppCleaner"
                button.target = self
                button.action = #selector(openFromMenuBar)
            }
            statusItem = item
        }
        model.scan(includeSystemApps: config.includeSystemApps)
    }

    func deactivate() {
        statusItem?.isVisible = false
        model.cancelScan()
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        statusItem?.isVisible = visible
    }

    var settingsStyle: ModuleSettingsStyle { .window }
    func makeSettingsPane() -> AnyView { AnyView(EmptyView()) }
    func openSettings() {
        settingsWindow.show()
        if model.apps.isEmpty { model.scan(includeSystemApps: config.includeSystemApps) }
    }

    @objc private func openFromMenuBar() { openSettings() }
}

final class AppCleanerConfig: ObservableObject {
    private enum Key {
        static let includeSystemApps = "includeSystemApps"
        static let includeLeftovers = "includeLeftovers"
        static let sort = "sort"
    }

    private let settings: Settings
    private let moduleID = ModuleCatalog.appCleaner.id

    @Published var includeSystemApps: Bool {
        didSet { settings.setModuleBool(includeSystemApps, id: moduleID, key: Key.includeSystemApps) }
    }
    @Published var includeLeftovers: Bool {
        didSet { settings.setModuleBool(includeLeftovers, id: moduleID, key: Key.includeLeftovers) }
    }
    @Published var sort: AppCleanerSort {
        didSet { settings.setModuleString(sort.rawValue, id: moduleID, key: Key.sort) }
    }

    init(settings: Settings) {
        self.settings = settings
        includeSystemApps = settings.moduleBool(id: moduleID, key: Key.includeSystemApps) ?? false
        includeLeftovers = settings.moduleBool(id: moduleID, key: Key.includeLeftovers) ?? true
        sort = AppCleanerSort(rawValue: settings.moduleString(id: moduleID, key: Key.sort) ?? "") ?? .size
    }
}

enum AppCleanerSort: String, CaseIterable, Identifiable {
    case size = "Size"
    case name = "Name"
    case modified = "Modified"
    var id: String { rawValue }
}

struct AppCleanerEntry: Identifiable, Equatable {
    let id: URL
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let appSize: Int64
    let modifiedAt: Date?
    let leftovers: [AppCleanerFile]

    var totalSize: Int64 { appSize + leftovers.reduce(0) { $0 + $1.size } }
}

struct AppCleanerFile: Identifiable, Equatable {
    let id: URL
    let url: URL
    let size: Int64
    let category: String
}

final class AppCleanerViewModel: ObservableObject {
    @Published private(set) var apps: [AppCleanerEntry] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scannedCount = 0
    @Published var selectedID: URL?
    @Published var errorMessage: String?

    private var scanID = UUID()

    func scan(includeSystemApps: Bool) {
        let id = UUID()
        scanID = id
        isScanning = true
        scannedCount = 0
        apps = []
        selectedID = nil
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let roots = Self.applicationRoots(includeSystemApps: includeSystemApps)
            let urls = roots.flatMap(Self.applications(in:))
            var results: [AppCleanerEntry] = []
            let resultLock = NSLock()
            let queue = OperationQueue()
            queue.name = "FreeKit.AppCleaner.Scan"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 4

            for url in urls {
                queue.addOperation { [weak self] in
                    guard self?.scanID == id else { return }
                    let entry = Self.inspect(url)
                    if let entry {
                        resultLock.lock()
                        results.append(entry)
                        resultLock.unlock()
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.scanID == id else { return }
                        self.scannedCount += 1
                        if let entry {
                            self.apps.append(entry)
                            if self.selectedID == nil { self.selectedID = entry.id }
                        }
                    }
                }
            }
            queue.waitUntilAllOperationsAreFinished()
            guard self?.scanID == id else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanID == id else { return }
                self.apps = results
                self.scannedCount = results.count
                self.isScanning = false
                if self.selectedID == nil { self.selectedID = results.first?.id }
            }
        }
    }

    func cancelScan() {
        scanID = UUID()
        isScanning = false
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func moveToTrash(_ entry: AppCleanerEntry, includeLeftovers: Bool) {
        var urls = [entry.url]
        if includeLeftovers { urls.append(contentsOf: entry.leftovers.map(\.url)) }
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.errorMessage = error.localizedDescription
                } else {
                    self?.apps.removeAll { $0.id == entry.id }
                    self?.selectedID = self?.apps.first?.id
                }
            }
        }
    }

    private static func applicationRoots(includeSystemApps: Bool) -> [URL] {
        var roots = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        if FileManager.default.fileExists(atPath: userApps.path) { roots.append(userApps) }
        if includeSystemApps {
            roots.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
        }
        return roots
    }

    private static func applications(in root: URL) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isApplicationKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return children.filter { $0.pathExtension.lowercased() == "app" }
    }

    private static func inspect(_ url: URL) -> AppCleanerEntry? {
        guard let bundle = Bundle(url: url) else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let identifier = bundle.bundleIdentifier
        return AppCleanerEntry(
            id: url,
            url: url,
            name: name,
            bundleIdentifier: identifier,
            version: version,
            appSize: allocatedSize(of: url),
            modifiedAt: values?.contentModificationDate,
            leftovers: findLeftovers(appName: name, bundleIdentifier: identifier))
    }

    private static func findLeftovers(appName: String, bundleIdentifier: String?) -> [AppCleanerFile] {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        let roots: [(String, String)] = [
            ("Application Support", "Application Support"),
            ("Caches", "Caches"),
            ("Preferences", "Preferences"),
            ("Saved Application State", "Saved State"),
            ("Logs", "Logs"),
            ("Containers", "Container"),
        ]
        let identifiers = [bundleIdentifier, appName].compactMap { $0?.lowercased() }
        guard !identifiers.isEmpty else { return [] }

        var found: [AppCleanerFile] = []
        for (folder, category) in roots {
            let root = library.appendingPathComponent(folder, isDirectory: true)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                let stem = child.deletingPathExtension().lastPathComponent.lowercased()
                let filename = child.lastPathComponent.lowercased()
                let exactMatch = identifiers.contains(stem) || identifiers.contains(filename)
                let bundleMatch = bundleIdentifier.map {
                    filename == $0.lowercased() || filename.hasPrefix($0.lowercased() + ".")
                } ?? false
                if exactMatch || bundleMatch {
                    found.append(AppCleanerFile(
                        id: child, url: child, size: allocatedSize(of: child), category: category))
                }
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        // `du` uses the filesystem's optimized directory traversal and is
        // dramatically faster than URL resource lookups for Xcode-sized apps.
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            guard finished.wait(timeout: .now() + 5) == .success else {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
                return 0
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8),
                  let kilobytes = Int64(output.split(whereSeparator: \.isWhitespace).first ?? "")
            else { return 0 }
            return kilobytes * 1024
        } catch {
            return 0
        }
    }
}

struct AppCleanerView: View {
    @ObservedObject var model: AppCleanerViewModel
    @ObservedObject var config: AppCleanerConfig
    @State private var query = ""
    @State private var pendingRemoval: AppCleanerEntry?

    private var filteredApps: [AppCleanerEntry] {
        let filtered = query.isEmpty ? model.apps : model.apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
        }
        switch config.sort {
        case .size: return filtered.sorted { $0.totalSize > $1.totalSize }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .modified: return filtered.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        }
    }

    private var selected: AppCleanerEntry? {
        filteredApps.first { $0.id == model.selectedID }
            ?? model.apps.first { $0.id == model.selectedID }
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            HStack(alignment: .top, spacing: 14) {
                appList
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
                Rectangle().fill(Color.dsLine).frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(height: 500)
        .alert("Move \(pendingRemoval?.name ?? "app") to Trash?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } })) {
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
                Button("Move to Trash", role: .destructive) {
                    if let entry = pendingRemoval {
                        model.moveToTrash(entry, includeLeftovers: config.includeLeftovers)
                    }
                    pendingRemoval = nil
                }
            } message: {
                Text(config.includeLeftovers
                     ? "The app and \(pendingRemoval?.leftovers.count ?? 0) matched support items will be moved to Trash."
                     : "Only the application will be moved to Trash.")
            }
        .alert("AppCleaner Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "Unknown error") }
        .onChange(of: config.includeSystemApps) { _, value in model.scan(includeSystemApps: value) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.dsFaint)
                TextField("Search applications", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dsPaper)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.dsInk2,
                        in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous)
                .strokeBorder(Color.dsLine, lineWidth: 1))

            Menu {
                ForEach(AppCleanerSort.allCases) { sort in
                    Button {
                        config.sort = sort
                    } label: {
                        if config.sort == sort { Label(sort.rawValue, systemImage: "checkmark") }
                        else { Text(sort.rawValue) }
                    }
                }
            } label: {
                Label(config.sort.rawValue, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button { model.scan(includeSystemApps: config.includeSystemApps) } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.dsMuted)
            .help("Rescan applications")
            .disabled(model.isScanning)
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DSSectionLabel(model.isScanning ? "Scanning \(model.scannedCount)" : "\(filteredApps.count) Applications")
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small).tint(Color.dsAccent) }
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredApps) { app in
                        Button { model.selectedID = app.id } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                    .resizable().scaledToFit().frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dsPaper)
                                        .lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Color.dsMuted)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 46)
                            .background(model.selectedID == app.id ? Color.dsInk3 : Color.clear,
                                        in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let app = selected {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().scaledToFit().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.system(size: 18, weight: .bold)).foregroundStyle(Color.dsPaper)
                        Text([app.version.map { "Version \($0)" }, app.bundleIdentifier]
                            .compactMap { $0 }.joined(separator: "  \u{00B7}  "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.dsMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    sizeMetric("Application", app.appSize)
                    sizeMetric("Leftovers", app.leftovers.reduce(0) { $0 + $1.size })
                    sizeMetric("Total", app.totalSize)
                }

                HStack {
                    DSSectionLabel("Matched Files")
                    Spacer()
                    DSToggleRow(title: "Include leftovers", isOn: $config.includeLeftovers)
                        .fixedSize()
                }
                ScrollView {
                    VStack(spacing: 1) {
                        fileRow(url: app.url, category: "Application", size: app.appSize)
                        ForEach(app.leftovers) { file in
                            fileRow(url: file.url, category: file.category, size: file.size)
                        }
                    }
                }

                HStack {
                    DSToggleRow(title: "Show system apps", isOn: $config.includeSystemApps)
                        .fixedSize()
                    Spacer()
                    Button("Reveal") { model.reveal(app.url) }
                        .buttonStyle(GhostButtonStyle())
                    Button("Move to Trash") { pendingRemoval = app }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 26)).foregroundStyle(Color.dsFaint)
                Text(model.isScanning ? "Scanning applications\u{2026}" : "Select an application")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sizeMetric(_ title: String, _ size: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.dsFaint)
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.dsPaper)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsInk2,
                    in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
    }

    private func fileRow(url: URL, category: String, size: Int64) -> some View {
        HStack(spacing: 10) {
            Image(systemName: category == "Application" ? "app" : "doc")
                .foregroundStyle(category == "Application" ? Color.dsAccent : Color.dsMuted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(category).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.dsPaper)
                Text(url.path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.dsFaint).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dsMuted)
            Button { model.reveal(url) } label: {
                Image(systemName: "arrow.right.circle").frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).foregroundStyle(Color.dsMuted).help("Reveal in Finder")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 42)
        .background(Color.dsInk1)
    }
}
