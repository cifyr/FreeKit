import AppKit
import SwiftUI
import IOKit
import IOKit.ps
import FreeSpeechCore

// Stats: live machine metrics, modeled like the Stats app — every stat can be
// shown in the dropdown, promoted to its own menu bar item, and each menu bar
// item gets its own display style. Dropdown sampling runs only while a menu is
// open; live menu-bar values share one background timer.
final class StatsModule: NSObject, AppModule, NSMenuDelegate {
    let info = ModuleCatalog.stats

    // One entry per stat the suite knows how to sample. Adding a stat here
    // gives it menu rows, an optional menu bar item, and settings for free.
    enum StatKind: String, CaseIterable, Hashable {
        case cpu, memory, gpu, network, disk, battery, system, bluetooth

        var displayName: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .gpu: return "GPU"
            case .network: return "Network"
            case .disk: return "Disk"
            case .battery: return "Battery"
            case .system: return "Uptime and load"
            case .bluetooth: return "Bluetooth battery"
            }
        }

        var symbolName: String {
            switch self {
            case .cpu: return "cpu"
            case .memory: return "memorychip"
            case .gpu: return "cube"
            case .network: return "arrow.up.arrow.down"
            case .disk: return "internaldrive"
            case .battery: return "battery.100percent"
            case .system: return "clock"
            case .bluetooth: return "wave.3.right"
            }
        }

        // Legacy key names from the first Stats release, kept so existing
        // show/hide choices survive.
        var showKey: String {
            switch self {
            case .cpu: return "showCPU"
            case .memory: return "showMemory"
            case .gpu: return "showGPU"
            case .network: return "showNetwork"
            case .disk: return "showDisk"
            case .battery: return "showBattery"
            case .system: return "showSystem"
            case .bluetooth: return "showBluetooth"
            }
        }

        var itemKey: String { "item.\(rawValue)" }
        var variantKey: String { "variant.\(rawValue)" }
        var iconKey: String { "itemIcon.\(rawValue)" }
        func rowKey(_ row: String) -> String { "row.\(rawValue).\(row)" }

        // Display variants for this stat's own menu bar item.
        var variants: [(id: String, name: String)] {
            switch self {
            case .cpu: return [("percent", "Percent"), ("cores", "Core bars")]
            case .memory: return [("percent", "Percent"), ("used", "Used GB")]
            case .gpu: return [("percent", "Percent")]
            case .network: return [("down", "Down"), ("up", "Up"), ("both", "Both")]
            case .disk: return [("free", "Free"), ("used", "Used"), ("percent", "Used %")]
            case .battery: return [("percent", "Percent"), ("time", "Time left")]
            case .system: return [("load", "Load"), ("uptime", "Uptime")]
            case .bluetooth: return [("lowest", "Lowest %")]
            }
        }

        // Individual dropdown rows, each toggleable so the dropdown shows
        // exactly what the user wants and nothing else.
        var rows: [(id: String, name: String)] {
            switch self {
            case .cpu: return [("usage", "Usage"), ("cores", "Per core"), ("top", "Top processes")]
            case .memory: return [("used", "Used"), ("breakdown", "Breakdown"),
                                  ("swap", "Swap"), ("top", "Top processes")]
            case .gpu: return [("utilization", "Utilization")]
            case .network: return [("down", "Down"), ("up", "Up"), ("address", "Address")]
            case .disk: return [("used", "Used"), ("free", "Free"), ("io", "Read/write")]
            case .battery: return [("level", "Level"), ("state", "State"),
                                   ("time", "Time"), ("cycles", "Cycles")]
            case .system: return [("uptime", "Uptime"), ("load", "Load")]
            case .bluetooth: return [("devices", "Devices")]
            }
        }
    }

    private let settings: Settings
    private let sampler = StatsSampler()
    private var mainItem: NSStatusItem?
    private var statItems: [StatKind: NSStatusItem] = [:]
    private var menuTimer: Timer?
    private var menuBarTimer: Timer?
    private let menu = NSMenu()
    private var menuBarVisible = false
    private var active = false
    private lazy var settingsWindow = ModuleSettingsWindowController(
        info: info,
        contentSize: NSSize(width: 640, height: 720),
        minimumSize: NSSize(width: 560, height: 480)
    ) { [weak self] in
        self?.makeSettingsPane() ?? AnyView(EmptyView())
    }

    enum Key {
        static let refreshInterval = "refreshInterval"
        static let showOverviewItem = "showOverviewItem"
        static let showHeaders = "showHeaders"
        static let showSeparators = "showSeparators"
        static let order = "order"
    }

    init(settings: Settings) {
        self.settings = settings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    private var refreshInterval: Double {
        settings.moduleDouble(id: info.id, key: Key.refreshInterval) ?? 1.0
    }

    private func showsInMenu(_ kind: StatKind) -> Bool {
        settings.moduleBool(id: info.id, key: kind.showKey) ?? true
    }

    private func hasOwnItem(_ kind: StatKind) -> Bool {
        settings.moduleBool(id: info.id, key: kind.itemKey) ?? false
    }

    private func variant(_ kind: StatKind) -> String {
        settings.moduleString(id: info.id, key: kind.variantKey) ?? kind.variants[0].id
    }

    private func showsIcon(_ kind: StatKind) -> Bool {
        settings.moduleBool(id: info.id, key: kind.iconKey) ?? true
    }

    private func showsRow(_ kind: StatKind, _ row: String) -> Bool {
        settings.moduleBool(id: info.id, key: kind.rowKey(row)) ?? true
    }

    private var showsOverviewItem: Bool {
        settings.moduleBool(id: info.id, key: Key.showOverviewItem) ?? true
    }

    private var showsHeaders: Bool {
        settings.moduleBool(id: info.id, key: Key.showHeaders) ?? true
    }

    private var showsSeparators: Bool {
        settings.moduleBool(id: info.id, key: Key.showSeparators) ?? true
    }

    static func orderedKinds(settings: Settings) -> [StatKind] {
        let saved = settings.moduleString(id: ModuleCatalog.stats.id, key: Key.order)?
            .split(separator: ",")
            .compactMap { StatKind(rawValue: String($0)) } ?? []
        var unique: [StatKind] = []
        for kind in saved where !unique.contains(kind) { unique.append(kind) }
        return unique + StatKind.allCases.filter { !unique.contains($0) }
    }

    static func saveOrder(_ order: [StatKind], settings: Settings) {
        settings.setModuleString(
            order.map(\.rawValue).joined(separator: ","),
            id: ModuleCatalog.stats.id, key: Key.order)
    }

    func activate() {
        active = true
        // Baseline the counters so the first menu open shows real deltas.
        sampler.sample()
        applyMenuBarConfiguration()
    }

    func deactivate() {
        active = false
        menuTimer?.invalidate()
        menuTimer = nil
        applyMenuBarConfiguration()
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        menuBarVisible = visible
        applyMenuBarConfiguration()
    }

    func openSettings() {
        settingsWindow.show()
    }

    func makeSettingsPane() -> AnyView {
        AnyView(StatsSettingsPane(settings: settings, onDisplayChange: { [weak self] in
            self?.applyMenuBarConfiguration()
        }))
    }

    // MARK: - Menu bar items

    // Rebuilds the whole set: the main gauge item plus one item per promoted
    // stat. Cheap enough to run on every settings change.
    private func applyMenuBarConfiguration() {
        let showAll = active && menuBarVisible

        if showAll && showsOverviewItem {
            if mainItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(
                    systemSymbolName: info.symbolName, accessibilityDescription: "Stats")
                item.button?.toolTip = "Stats"
                item.menu = menu
                mainItem = item
            }
            mainItem?.isVisible = true
        } else {
            mainItem?.isVisible = false
        }

        for kind in StatKind.allCases {
            let wanted = showAll && hasOwnItem(kind)
            if wanted {
                if statItems[kind] == nil {
                    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                    item.button?.toolTip = "Stats: \(kind.displayName)"
                    // All stat items share the one dropdown; whichever opens it
                    // sees the same live overview.
                    item.menu = menu
                    statItems[kind] = item
                }
                statItems[kind]?.isVisible = true
            } else {
                statItems[kind]?.isVisible = false
            }
        }

        reconfigureMenuBarTimer()
        updateStatItems(sampleNow: true)
    }

    private var anyLiveItems: Bool {
        active && menuBarVisible && StatKind.allCases.contains { hasOwnItem($0) }
    }

    private func reconfigureMenuBarTimer() {
        menuBarTimer?.invalidate()
        menuBarTimer = nil
        guard anyLiveItems else { return }
        // Background updates are capped at one per 2s: menu-bar text does not
        // need dropdown-grade freshness.
        let timer = Timer(timeInterval: max(refreshInterval, 2.0), repeats: true) { [weak self] _ in
            self?.updateStatItems(sampleNow: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        menuBarTimer = timer
    }

    private func updateStatItems(sampleNow: Bool) {
        guard anyLiveItems else { return }
        let snapshot = sampleNow ? sampler.sample() : sampler.lastSnapshot
        for (kind, item) in statItems where item.isVisible {
            guard let button = item.button else { continue }
            let text = menuBarText(kind: kind, snapshot: snapshot)
            button.image = showsIcon(kind)
                ? NSImage(systemSymbolName: kind.symbolName,
                          accessibilityDescription: kind.displayName)
                : nil
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        }
    }

    private func menuBarText(kind: StatKind, snapshot: StatsSnapshot) -> String {
        switch (kind, variant(kind)) {
        case (.cpu, "cores"):
            return StatsFormatting.coreBars(snapshot.perCoreUsage)
        case (.cpu, _):
            return StatsFormatting.percent(snapshot.cpuUsage)
        case (.gpu, _):
            return snapshot.gpuUtilization.map(StatsFormatting.percent) ?? "\u{2014}"
        case (.battery, "time"):
            return snapshot.batteryMinutesRemaining.map(StatsFormatting.minutes) ?? "\u{2014}"
        case (.memory, "used"):
            return StatsFormatting.bytes(snapshot.memoryUsed)
        case (.memory, _):
            return StatsFormatting.percent(snapshot.memoryUsed / max(snapshot.memoryTotal, 1))
        case (.network, "up"):
            return "\u{2191}\(StatsFormatting.bytesPerSecond(snapshot.uploadBytesPerSecond))"
        case (.network, "both"):
            return "\u{2193}\(StatsFormatting.bytesPerSecond(snapshot.downloadBytesPerSecond)) \u{2191}\(StatsFormatting.bytesPerSecond(snapshot.uploadBytesPerSecond))"
        case (.network, _):
            return "\u{2193}\(StatsFormatting.bytesPerSecond(snapshot.downloadBytesPerSecond))"
        case (.disk, "used"):
            return StatsFormatting.bytes(snapshot.diskUsed)
        case (.disk, "percent"):
            return StatsFormatting.percent(snapshot.diskUsed / max(snapshot.diskTotal, 1))
        case (.disk, _):
            return "\(StatsFormatting.bytes(snapshot.diskFree)) free"
        case (.battery, _):
            return snapshot.batteryPercent.map { "\($0)%" } ?? "\u{2014}"
        case (.system, "uptime"):
            return StatsFormatting.uptime(snapshot.uptime)
        case (.system, _):
            return String(format: "%.2f", snapshot.loadAverages.0)
        case (.bluetooth, _):
            let lowest = sampler.bluetoothBatteries().map(\.percent).min()
            return lowest.map { "\($0)%" } ?? "\u{2014}"
        }
    }

    // MARK: - Menu lifecycle

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
        // .common mode keeps the timer firing during menu tracking.
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.rebuild()
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    private func rebuild() {
        let snapshot = sampler.sample()
        menu.removeAllItems()

        var addedSection = false
        for kind in Self.orderedKinds(settings: settings) where showsInMenu(kind) {
            let rows = menuRows(for: kind, snapshot: snapshot)
            guard !rows.isEmpty else { continue }
            if addedSection, showsSeparators { menu.addItem(.separator()) }
            if showsHeaders { addHeader(kind.displayName.uppercased()) }
            rows.forEach { addMetric($0.label, $0.value) }
            addedSection = true
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Stats Settings\u{2026}", action: #selector(openSettingsFromMenu),
            keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    private func menuRows(
        for kind: StatKind, snapshot: StatsSnapshot
    ) -> [(label: String, value: String)] {
        switch kind {
        case .cpu:
            var rows: [(String, String)] = []
            if showsRow(kind, "usage") {
                rows.append(("CPU", StatsFormatting.percent(snapshot.cpuUsage)))
            }
            if showsRow(kind, "cores"), !snapshot.perCoreUsage.isEmpty {
                rows.append(("Cores", StatsFormatting.coreBars(snapshot.perCoreUsage)))
            }
            if showsRow(kind, "top") {
                for process in sampler.topProcesses(byMemory: false) {
                    rows.append(("   \(process.name)", process.value))
                }
            }
            return rows
        case .memory:
            var rows: [(String, String)] = []
            if showsRow(kind, "used") {
                rows.append(("Memory", "\(StatsFormatting.bytes(snapshot.memoryUsed)) of \(StatsFormatting.bytes(snapshot.memoryTotal)) (\(StatsFormatting.percent(snapshot.memoryUsed / max(snapshot.memoryTotal, 1))))"))
            }
            if showsRow(kind, "breakdown") {
                rows.append(("Active", StatsFormatting.bytes(snapshot.memoryActive)))
                rows.append(("Wired", StatsFormatting.bytes(snapshot.memoryWired)))
                rows.append(("Compressed", StatsFormatting.bytes(snapshot.memoryCompressed)))
            }
            if showsRow(kind, "swap"), snapshot.swapUsed > 0 {
                rows.append(("Swap", StatsFormatting.bytes(snapshot.swapUsed)))
            }
            if showsRow(kind, "top") {
                for process in sampler.topProcesses(byMemory: true) {
                    rows.append(("   \(process.name)", process.value))
                }
            }
            return rows
        case .gpu:
            guard showsRow(kind, "utilization"), let utilization = snapshot.gpuUtilization else {
                return []
            }
            return [("GPU", StatsFormatting.percent(utilization))]
        case .network:
            var rows: [(String, String)] = []
            if showsRow(kind, "down") { rows.append(("Down", StatsFormatting.bytesPerSecond(snapshot.downloadBytesPerSecond))) }
            if showsRow(kind, "up") { rows.append(("Up", StatsFormatting.bytesPerSecond(snapshot.uploadBytesPerSecond))) }
            if showsRow(kind, "address"), let address = snapshot.localIPv4 {
                rows.append(("Address", address))
            }
            return rows
        case .disk:
            var rows: [(String, String)] = []
            if showsRow(kind, "used") { rows.append(("Used", "\(StatsFormatting.bytes(snapshot.diskUsed)) of \(StatsFormatting.bytes(snapshot.diskTotal))")) }
            if showsRow(kind, "free") { rows.append(("Free", StatsFormatting.bytes(snapshot.diskFree))) }
            if showsRow(kind, "io") {
                rows.append(("Read", StatsFormatting.bytesPerSecond(snapshot.diskReadPerSecond)))
                rows.append(("Write", StatsFormatting.bytesPerSecond(snapshot.diskWritePerSecond)))
            }
            return rows
        case .battery:
            guard let percent = snapshot.batteryPercent else { return [] }
            var rows: [(String, String)] = []
            if showsRow(kind, "level") { rows.append(("Level", "\(percent)%")) }
            if showsRow(kind, "state") { rows.append(("State", snapshot.batteryCharging ? "Charging" : "On battery")) }
            if showsRow(kind, "time"), let minutes = snapshot.batteryMinutesRemaining {
                rows.append((snapshot.batteryCharging ? "Until full" : "Remaining",
                             StatsFormatting.minutes(minutes)))
            }
            if showsRow(kind, "cycles"), let cycles = snapshot.batteryCycleCount {
                rows.append(("Cycles", "\(cycles)"))
            }
            return rows
        case .system:
            var rows: [(String, String)] = []
            if showsRow(kind, "uptime") { rows.append(("Uptime", StatsFormatting.uptime(snapshot.uptime))) }
            if showsRow(kind, "load") { rows.append(("Load", String(format: "%.2f  %.2f  %.2f", snapshot.loadAverages.0, snapshot.loadAverages.1, snapshot.loadAverages.2))) }
            return rows
        case .bluetooth:
            guard showsRow(kind, "devices") else { return [] }
            let devices = sampler.bluetoothBatteries()
            return devices.isEmpty
                ? [("No devices reporting battery", "")]
                : devices.map { ($0.name, StatsFormatting.percent(Double($0.percent) / 100)) }
        }
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    private func addHeader(_ text: String) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .kern: 1.2,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addMetric(_ label: String, _ value: String) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let title = NSMutableAttributedString(
            string: label + (value.isEmpty ? "" : "  "),
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        // Monospaced digits so refreshing values don't jitter horizontally.
        title.append(NSAttributedString(
            string: value,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)]))
        item.attributedTitle = title
        item.isEnabled = true
        menu.addItem(item)
    }
}

// MARK: - Settings pane

private final class StatsPreviewModel: ObservableObject {
    @Published private(set) var snapshot: StatsSnapshot
    @Published private(set) var bluetooth: [BluetoothBattery]
    private let sampler: StatsSampler
    private var timer: Timer?

    init() {
        let sampler = StatsSampler()
        sampler.sample()
        self.sampler = sampler
        snapshot = sampler.sample()
        bluetooth = sampler.bluetoothBatteries()
    }

    func start(every interval: Double) {
        stop()
        sample()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        snapshot = sampler.sample()
        bluetooth = sampler.bluetoothBatteries()
    }
}

private struct StatsSettingsPane: View {
    private enum Tab: String, CaseIterable { case live = "Live data", dropdown = "Dropdown", menuBar = "Menu bar" }

    let settings: Settings
    let onDisplayChange: () -> Void
    private let moduleID = ModuleCatalog.stats.id
    @StateObject private var preview = StatsPreviewModel()
    @State private var tab: Tab = .live
    @State private var refresh: Double
    @State private var showHeaders: Bool
    @State private var showSeparators: Bool
    @State private var showOverviewItem: Bool
    @State private var order: [StatsModule.StatKind]

    init(settings: Settings, onDisplayChange: @escaping () -> Void) {
        self.settings = settings
        self.onDisplayChange = onDisplayChange
        let id = ModuleCatalog.stats.id
        _refresh = State(initialValue: settings.moduleDouble(
            id: id, key: StatsModule.Key.refreshInterval) ?? 1.0)
        _showHeaders = State(initialValue: settings.moduleBool(
            id: id, key: StatsModule.Key.showHeaders) ?? true)
        _showSeparators = State(initialValue: settings.moduleBool(
            id: id, key: StatsModule.Key.showSeparators) ?? true)
        _showOverviewItem = State(initialValue: settings.moduleBool(
            id: id, key: StatsModule.Key.showOverviewItem) ?? true)
        _order = State(initialValue: StatsModule.orderedKinds(settings: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 22) {
                ForEach(Tab.allCases, id: \.self) { value in
                    DSTabButton(title: value.rawValue, selected: tab == value) { tab = value }
                }
                Spacer()
            }
            Rectangle().fill(Color.dsLine).frame(height: 1)

            switch tab {
            case .live: liveTab
            case .dropdown: dropdownTab
            case .menuBar: menuBarTab
            }
        }
        .onAppear { preview.start(every: refresh) }
        .onDisappear { preview.stop() }
        .onChange(of: refresh) { _, value in preview.start(every: value) }
    }

    @ViewBuilder private var liveTab: some View {
        DSSettingsCard(title: "Live machine") {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading, spacing: 16
            ) {
                previewValue("CPU", StatsFormatting.percent(preview.snapshot.cpuUsage), "cpu")
                previewValue(
                    "Memory",
                    "\(StatsFormatting.bytes(preview.snapshot.memoryUsed)) / \(StatsFormatting.bytes(preview.snapshot.memoryTotal))",
                    "memorychip")
                previewValue("Download", StatsFormatting.bytesPerSecond(preview.snapshot.downloadBytesPerSecond), "arrow.down")
                previewValue("Upload", StatsFormatting.bytesPerSecond(preview.snapshot.uploadBytesPerSecond), "arrow.up")
                previewValue("Disk free", StatsFormatting.bytes(preview.snapshot.diskFree), "internaldrive")
                previewValue("Uptime", StatsFormatting.uptime(preview.snapshot.uptime), "clock")
                if let battery = preview.snapshot.batteryPercent {
                    previewValue("Battery", "\(battery)%", "battery.100percent")
                }
                previewValue("Bluetooth", preview.bluetooth.isEmpty ? "No battery data" : "\(preview.bluetooth.count) devices", "wave.3.right")
            }
        }

        DSSettingsCard(title: "Refresh") {
            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 2.0, 5.0], id: \.self) { value in
                    DSChip(
                        title: String(format: value < 1 ? "%.1fs" : "%.0fs", value),
                        selected: refresh == value
                    ) {
                        refresh = value
                        settings.setModuleDouble(value, id: moduleID, key: StatsModule.Key.refreshInterval)
                        onDisplayChange()
                    }
                }
            }
            Text("Dropdown values use this interval. Standalone menu-bar values are capped at a two-second minimum.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dsFaint)
        }
    }

    @ViewBuilder private var dropdownTab: some View {
        DSSettingsCard(title: "Layout") {
            DSToggleRow(title: "Show section headings", isOn: Binding(
                get: { showHeaders },
                set: {
                    showHeaders = $0
                    settings.setModuleBool($0, id: moduleID, key: StatsModule.Key.showHeaders)
                }))
            DSToggleRow(title: "Separate metric groups", isOn: Binding(
                get: { showSeparators },
                set: {
                    showSeparators = $0
                    settings.setModuleBool($0, id: moduleID, key: StatsModule.Key.showSeparators)
                }))
            Text("Use the arrows below to choose the order in the Stats dropdown.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dsFaint)
        }
        LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
            ForEach(order, id: \.self) { kind in
                StatsDropdownSection(
                    settings: settings,
                    kind: kind,
                    canMoveUp: order.first != kind,
                    canMoveDown: order.last != kind,
                    moveUp: { move(kind, by: -1) },
                    moveDown: { move(kind, by: 1) })
            }
        }
    }

    @ViewBuilder private var menuBarTab: some View {
        DSSettingsCard(title: "Overview item") {
            DSToggleRow(
                title: "Show Stats overview icon",
                caption: "The gauge opens the full dropdown. Individual metrics can still appear beside it.",
                isOn: Binding(
                    get: { showOverviewItem },
                    set: {
                        showOverviewItem = $0
                        settings.setModuleBool($0, id: moduleID, key: StatsModule.Key.showOverviewItem)
                        onDisplayChange()
                    }))
        }
        LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
            ForEach(StatsModule.StatKind.allCases, id: \.self) { kind in
                StatsMenuBarSection(settings: settings, kind: kind, onDisplayChange: onDisplayChange)
            }
        }
    }

    private func move(_ kind: StatsModule.StatKind, by offset: Int) {
        guard let index = order.firstIndex(of: kind) else { return }
        let destination = index + offset
        guard order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
        StatsModule.saveOrder(order, settings: settings)
    }

    private var metricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)]
    }

    private func previewValue(_ label: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dsAccent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(Color.dsFaint)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dsPaper)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

private struct StatsDropdownSection: View {
    let settings: Settings
    let kind: StatsModule.StatKind
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    private let moduleID = ModuleCatalog.stats.id
    @State private var inMenu: Bool

    init(
        settings: Settings, kind: StatsModule.StatKind,
        canMoveUp: Bool, canMoveDown: Bool,
        moveUp: @escaping () -> Void, moveDown: @escaping () -> Void
    ) {
        self.settings = settings
        self.kind = kind
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.moveUp = moveUp
        self.moveDown = moveDown
        _inMenu = State(initialValue: settings.moduleBool(
            id: ModuleCatalog.stats.id, key: kind.showKey) ?? true)
    }

    var body: some View {
        DSSettingsCard(title: kind.displayName) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(Color.dsMuted)
                Text("Dropdown position")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
                Spacer()
                orderButton("chevron.up", enabled: canMoveUp, action: moveUp)
                orderButton("chevron.down", enabled: canMoveDown, action: moveDown)
            }
            DSToggleRow(title: "Show in dropdown", isOn: Binding(
                get: { inMenu },
                set: {
                    inMenu = $0
                    settings.setModuleBool($0, id: moduleID, key: kind.showKey)
                }))
            if inMenu {
                HStack(spacing: 14) {
                    Text("Rows")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                    ForEach(kind.rows, id: \.id) { row in rowCheckbox(row) }
                    Spacer()
                }
            }
        }
    }

    private func rowCheckbox(_ row: (id: String, name: String)) -> some View {
        HStack(spacing: 6) {
            DSCheckbox(isOn: Binding(
                get: { settings.moduleBool(id: moduleID, key: kind.rowKey(row.id)) ?? true },
                set: { settings.setModuleBool($0, id: moduleID, key: kind.rowKey(row.id)) }))
            Text(row.name).font(.system(size: 11)).foregroundStyle(Color.dsPaper)
        }
    }

    private func orderButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? Color.dsMuted : Color.dsFaint)
                .frame(width: 24, height: 24)
                .background(Color.dsInk2, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct StatsMenuBarSection: View {
    let settings: Settings
    let kind: StatsModule.StatKind
    let onDisplayChange: () -> Void
    private let moduleID = ModuleCatalog.stats.id
    @State private var ownItem: Bool
    @State private var variant: String
    @State private var icon: Bool

    init(settings: Settings, kind: StatsModule.StatKind, onDisplayChange: @escaping () -> Void) {
        self.settings = settings
        self.kind = kind
        self.onDisplayChange = onDisplayChange
        let id = ModuleCatalog.stats.id
        _ownItem = State(initialValue: settings.moduleBool(id: id, key: kind.itemKey) ?? false)
        _variant = State(initialValue: settings.moduleString(id: id, key: kind.variantKey)
            ?? kind.variants[0].id)
        _icon = State(initialValue: settings.moduleBool(id: id, key: kind.iconKey) ?? true)
    }

    var body: some View {
        DSSettingsCard(title: kind.displayName) {
            DSToggleRow(title: "Own menu bar item", isOn: Binding(
                get: { ownItem },
                set: {
                    ownItem = $0
                    settings.setModuleBool($0, id: moduleID, key: kind.itemKey)
                    onDisplayChange()
                }))
            if ownItem {
                HStack(spacing: 8) {
                    ForEach(kind.variants, id: \.id) { option in
                        DSChip(title: option.name, selected: variant == option.id) {
                            variant = option.id
                            settings.setModuleString(option.id, id: moduleID, key: kind.variantKey)
                            onDisplayChange()
                        }
                    }
                    DSChip(title: "Icon", selected: icon) {
                        icon.toggle()
                        settings.setModuleBool(icon, id: moduleID, key: kind.iconKey)
                        onDisplayChange()
                    }
                }
            }
        }
    }
}

// MARK: - Sampling

struct StatsSnapshot {
    var cpuUsage: Double = 0        // 0...1
    var perCoreUsage: [Double] = [] // 0...1 per core
    var memoryUsed: Double = 0      // bytes
    var memoryTotal: Double = 0     // bytes
    var memoryActive: Double = 0    // bytes
    var memoryWired: Double = 0     // bytes
    var memoryCompressed: Double = 0
    var swapUsed: Double = 0        // bytes
    var gpuUtilization: Double?     // 0...1, nil when the GPU exposes no counter
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
    var localIPv4: String?
    var diskUsed: Double = 0        // bytes
    var diskFree: Double = 0        // bytes
    var diskTotal: Double = 0       // bytes
    var diskReadPerSecond: Double = 0
    var diskWritePerSecond: Double = 0
    var uptime: TimeInterval = 0
    var loadAverages: (Double, Double, Double) = (0, 0, 0)
    // nil on machines without an internal battery.
    var batteryPercent: Int?
    var batteryCharging = false
    var batteryMinutesRemaining: Int?
    var batteryCycleCount: Int?
}

struct BluetoothBattery {
    let name: String
    let percent: Int
}

final class StatsSampler {
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastPerCoreTicks: [(busy: UInt64, total: UInt64)] = []
    private var lastNetBytes: (received: UInt64, sent: UInt64)?
    private var lastDiskBytes: (read: UInt64, written: UInt64)?
    private var lastSampleTime: CFAbsoluteTime?
    private(set) var lastSnapshot = StatsSnapshot()

    @discardableResult
    func sample() -> StatsSnapshot {
        var snapshot = StatsSnapshot()
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = lastSampleTime.map { now - $0 } ?? 0
        lastSampleTime = now

        // CPU: whole-machine tick counters; usage is the busy share of the delta.
        var loadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let cpuResult = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if cpuResult == KERN_SUCCESS {
            let user = UInt64(loadInfo.cpu_ticks.0)
            let system = UInt64(loadInfo.cpu_ticks.1)
            let idle = UInt64(loadInfo.cpu_ticks.2)
            let nice = UInt64(loadInfo.cpu_ticks.3)
            let busy = user + system + nice
            let total = busy + idle
            if let last = lastCPUTicks, total > last.total {
                let busyDelta = Double(busy - last.busy)
                let totalDelta = Double(total - last.total)
                snapshot.cpuUsage = totalDelta > 0 ? busyDelta / totalDelta : 0
            }
            lastCPUTicks = (busy, total)
        } else {
            Log.error("stats: host_statistics(HOST_CPU_LOAD_INFO) failed: \(cpuResult)")
        }

        // Memory: app-visible "used" the way Activity Monitor frames it —
        // active + wired + compressed.
        var vmStats = vm_statistics64()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let vmResult = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmResult == KERN_SUCCESS {
            let pageSize = Double(vm_kernel_page_size)
            snapshot.memoryActive = Double(vmStats.active_count) * pageSize
            snapshot.memoryWired = Double(vmStats.wire_count) * pageSize
            snapshot.memoryCompressed = Double(vmStats.compressor_page_count) * pageSize
            snapshot.memoryUsed = snapshot.memoryActive + snapshot.memoryWired
                + snapshot.memoryCompressed
        } else {
            Log.error("stats: host_statistics64(HOST_VM_INFO64) failed: \(vmResult)")
        }
        snapshot.memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)

        snapshot.perCoreUsage = samplePerCore()
        snapshot.gpuUtilization = Self.gpuUtilization()

        // Swap via sysctl; failure just leaves the row out (swapUsed == 0).
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            snapshot.swapUsed = Double(swap.xsu_used)
        }

        // Network: sum of per-interface counters (loopback excluded), rate from
        // the delta since the previous sample.
        let (received, sent) = Self.interfaceByteCounts()
        if let last = lastNetBytes, elapsed > 0 {
            snapshot.downloadBytesPerSecond = StatsFormatting.throughput(
                previous: last.received, current: received, seconds: elapsed)
            snapshot.uploadBytesPerSecond = StatsFormatting.throughput(
                previous: last.sent, current: sent, seconds: elapsed)
        }
        lastNetBytes = (received, sent)
        snapshot.localIPv4 = Self.primaryIPv4()

        // Disk activity: whole-machine block-storage counters, rate from delta.
        let (read, written) = Self.diskByteCounts()
        if let last = lastDiskBytes, elapsed > 0 {
            snapshot.diskReadPerSecond = StatsFormatting.throughput(
                previous: last.read, current: read, seconds: elapsed)
            snapshot.diskWritePerSecond = StatsFormatting.throughput(
                previous: last.written, current: written, seconds: elapsed)
        }
        lastDiskBytes = (read, written)

        // Disk: the root volume is the one that fills up and hurts.
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ])
            if let total = values.volumeTotalCapacity,
               let free = values.volumeAvailableCapacityForImportantUsage {
                snapshot.diskTotal = Double(total)
                snapshot.diskFree = Double(free)
                snapshot.diskUsed = Double(total) - Double(free)
            }
        } catch {
            Log.error("stats: disk capacity query failed: \(error.localizedDescription)")
        }

        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            snapshot.loadAverages = (loads[0], loads[1], loads[2])
        }

        let battery = Self.internalBattery()
        snapshot.batteryPercent = battery.percent
        snapshot.batteryCharging = battery.charging
        snapshot.batteryMinutesRemaining = battery.minutes
        snapshot.batteryCycleCount = battery.cycles

        lastSnapshot = snapshot
        return snapshot
    }

    // The Mac's own battery via IOPowerSources; percent nil on desktops.
    private static func internalBattery() -> (percent: Int?, charging: Bool, minutes: Int?, cycles: Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false, nil, nil)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            // -1 means "still calculating"; surface as unknown.
            let rawMinutes = (charging
                ? description[kIOPSTimeToFullChargeKey]
                : description[kIOPSTimeToEmptyKey]) as? Int ?? -1
            return (Int((Double(current) / Double(max) * 100).rounded()), charging,
                    rawMinutes > 0 ? rawMinutes : nil, batteryCycleCount())
        }
        return (nil, false, nil, nil)
    }

    // Cycle count only lives in the AppleSmartBattery registry entry.
    private static func batteryCycleCount() -> Int? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }

    // Per-core busy share since the previous sample, in core order.
    private func samplePerCore() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else {
            Log.error("stats: host_processor_info failed: \(result)")
            return []
        }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var usages: [Double] = []
        var newTicks: [(busy: UInt64, total: UInt64)] = []
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            let busy = user + system + nice
            let total = busy + idle
            if core < lastPerCoreTicks.count, total > lastPerCoreTicks[core].total {
                let last = lastPerCoreTicks[core]
                usages.append(Double(busy - last.busy) / Double(total - last.total))
            } else {
                usages.append(0)
            }
            newTicks.append((busy, total))
        }
        lastPerCoreTicks = newTicks
        return usages
    }

    // Apple Silicon GPUs expose a utilization counter through IOAccelerator.
    private static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(
                    service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let utilization = stats["Device Utilization %"] as? Int else { continue }
            return Double(utilization) / 100.0
        }
        return nil
    }

    // Whole-machine block-storage read/write byte counters.
    private static func diskByteCounts() -> (read: UInt64, written: UInt64) {
        var read: UInt64 = 0
        var written: UInt64 = 0
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
        guard result == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(
                    service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? UInt64) ?? 0
            written &+= (stats["Bytes (Written)"] as? UInt64) ?? 0
        }
        return (read, written)
    }

    // First non-loopback IPv4, preferring en0 (Wi-Fi / first Ethernet).
    private static func primaryIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var best: (name: String, address: String)?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if name == "en0" { return "\(name) \(address)" }
            if best == nil { best = (name, address) }
        }
        return best.map { "\($0.name) \($0.address)" }
    }

    // Top three processes via ps, matching how Activity Monitor ranks them.
    // Only called while the dropdown is open and the row is enabled.
    func topProcesses(byMemory: Bool) -> [(name: String, value: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = byMemory
            ? ["-Aceo", "rss=,comm=", "-m"]
            : ["-Aceo", "pcpu=,comm=", "-r"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Log.error("stats: ps failed: \(error.localizedDescription)")
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").prefix(3).compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let number = Double(parts[0]) else { return nil }
            let name = String(parts[1])
            return byMemory
                ? (name, StatsFormatting.bytes(number * 1024))  // rss is KiB
                : (name, String(format: "%.1f%%", number))
        }
    }

    private static func interfaceByteCounts() -> (received: UInt64, sent: UInt64) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else {
            Log.error("stats: getifaddrs failed: \(String(cString: strerror(errno)))")
            return (0, 0)
        }
        defer { freeifaddrs(addrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = current.pointee.ifa_data else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            received &+= UInt64(data.ifi_ibytes)
            sent &+= UInt64(data.ifi_obytes)
        }
        return (received, sent)
    }

    // Battery levels surface in the IORegistry for HID-over-Bluetooth devices
    // (Magic keyboards/mice/trackpads, many headphones). There is no public API
    // for other iCloud devices' batteries — if one ever appears, plug it in
    // here alongside the HID scan.
    func bluetoothBatteries() -> [BluetoothBattery] {
        var results: [BluetoothBattery] = []
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            Log.error("stats: IOServiceGetMatchingServices failed: \(result)")
            return []
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let percent = registryProperty(service, "BatteryPercent") as? Int else { continue }
            let name = (registryProperty(service, "Product") as? String) ?? "Bluetooth device"
            results.append(BluetoothBattery(name: name, percent: percent))
        }
        return results.sorted { $0.name < $1.name }
    }

    private func registryProperty(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
