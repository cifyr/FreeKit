import AppKit
import SwiftUI
import IOKit
import FreeSpeechCore

// Stats: live machine metrics, modeled like the Stats app — every stat can be
// shown in the dropdown, promoted to its own menu bar item, and each menu bar
// item gets its own display style. Dropdown sampling runs only while a menu is
// open; live menu-bar values share one background timer.
final class StatsModule: NSObject, AppModule, NSMenuDelegate {
    let info = ModuleCatalog.stats

    // One entry per stat the suite knows how to sample. Adding a stat here
    // gives it menu rows, an optional menu bar item, and settings for free.
    enum StatKind: String, CaseIterable {
        case cpu, memory, network, disk, system, bluetooth

        var displayName: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .network: return "Network"
            case .disk: return "Disk"
            case .system: return "Uptime and load"
            case .bluetooth: return "Bluetooth battery"
            }
        }

        var symbolName: String {
            switch self {
            case .cpu: return "cpu"
            case .memory: return "memorychip"
            case .network: return "arrow.up.arrow.down"
            case .disk: return "internaldrive"
            case .system: return "clock"
            case .bluetooth: return "battery.75percent"
            }
        }

        // Legacy key names from the first Stats release, kept so existing
        // show/hide choices survive.
        var showKey: String {
            switch self {
            case .cpu: return "showCPU"
            case .memory: return "showMemory"
            case .network: return "showNetwork"
            case .disk: return "showDisk"
            case .system: return "showSystem"
            case .bluetooth: return "showBluetooth"
            }
        }

        var itemKey: String { "item.\(rawValue)" }
        var variantKey: String { "variant.\(rawValue)" }
        var iconKey: String { "itemIcon.\(rawValue)" }

        // Display variants for this stat's own menu bar item.
        var variants: [(id: String, name: String)] {
            switch self {
            case .cpu: return [("percent", "Percent")]
            case .memory: return [("percent", "Percent"), ("used", "Used GB")]
            case .network: return [("down", "Down"), ("up", "Up"), ("both", "Both")]
            case .disk: return [("free", "Free"), ("used", "Used"), ("percent", "Used %")]
            case .system: return [("load", "Load"), ("uptime", "Uptime")]
            case .bluetooth: return [("lowest", "Lowest %")]
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
    private lazy var settingsWindow = ModuleSettingsWindowController(info: info) { [weak self] in
        self?.makeSettingsPane() ?? AnyView(EmptyView())
    }

    enum Key {
        static let refreshInterval = "refreshInterval"
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

        if showAll {
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
        case (.cpu, _):
            return StatsFormatting.percent(snapshot.cpuUsage)
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

        if showsInMenu(.cpu) || showsInMenu(.memory) {
            addHeader("MACHINE")
            if showsInMenu(.cpu) {
                addMetric("CPU", StatsFormatting.percent(snapshot.cpuUsage))
            }
            if showsInMenu(.memory) {
                addMetric("Memory", "\(StatsFormatting.bytes(snapshot.memoryUsed)) of \(StatsFormatting.bytes(snapshot.memoryTotal)) (\(StatsFormatting.percent(snapshot.memoryUsed / max(snapshot.memoryTotal, 1))))")
                if snapshot.swapUsed > 0 {
                    addMetric("Swap", StatsFormatting.bytes(snapshot.swapUsed))
                }
            }
        }

        if showsInMenu(.network) {
            menu.addItem(.separator())
            addHeader("NETWORK")
            addMetric("Down", StatsFormatting.bytesPerSecond(snapshot.downloadBytesPerSecond))
            addMetric("Up", StatsFormatting.bytesPerSecond(snapshot.uploadBytesPerSecond))
        }

        if showsInMenu(.disk) {
            menu.addItem(.separator())
            addHeader("DISK")
            addMetric("Used", "\(StatsFormatting.bytes(snapshot.diskUsed)) of \(StatsFormatting.bytes(snapshot.diskTotal))")
            addMetric("Free", StatsFormatting.bytes(snapshot.diskFree))
        }

        if showsInMenu(.system) {
            menu.addItem(.separator())
            addHeader("SYSTEM")
            addMetric("Uptime", StatsFormatting.uptime(snapshot.uptime))
            addMetric("Load", String(format: "%.2f  %.2f  %.2f",
                                     snapshot.loadAverages.0, snapshot.loadAverages.1,
                                     snapshot.loadAverages.2))
        }

        if showsInMenu(.bluetooth) {
            menu.addItem(.separator())
            addHeader("BLUETOOTH BATTERY")
            let devices = sampler.bluetoothBatteries()
            if devices.isEmpty {
                addMetric("No devices reporting battery", "")
            } else {
                for device in devices {
                    addMetric(device.name, StatsFormatting.percent(Double(device.percent) / 100))
                }
            }
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Stats Settings\u{2026}", action: #selector(openSettingsFromMenu),
            keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
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

private struct StatsSettingsPane: View {
    let settings: Settings
    let onDisplayChange: () -> Void

    private let moduleID = ModuleCatalog.stats.id
    @State private var refresh: Double

    init(settings: Settings, onDisplayChange: @escaping () -> Void) {
        self.settings = settings
        self.onDisplayChange = onDisplayChange
        _refresh = State(initialValue: settings.moduleDouble(
            id: ModuleCatalog.stats.id, key: StatsModule.Key.refreshInterval) ?? 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                DSSectionLabel("Refresh every")
                HStack(spacing: 8) {
                    ForEach([0.5, 1.0, 2.0, 5.0], id: \.self) { value in
                        DSChip(title: String(format: value < 1 ? "%.1fs" : "%.0fs", value),
                               selected: refresh == value) {
                            refresh = value
                            settings.setModuleDouble(value, id: moduleID, key: StatsModule.Key.refreshInterval)
                            onDisplayChange()
                        }
                    }
                }
                Text("Applies to the dropdown; standalone menu bar values update at this pace, 2s minimum.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }

            ForEach(StatsModule.StatKind.allCases, id: \.rawValue) { kind in
                StatKindSection(
                    settings: settings, kind: kind, onDisplayChange: onDisplayChange)
            }
        }
    }
}

// Per-stat block: dropdown visibility, own menu bar item, and that item's style.
private struct StatKindSection: View {
    let settings: Settings
    let kind: StatsModule.StatKind
    let onDisplayChange: () -> Void

    private let moduleID = ModuleCatalog.stats.id
    @State private var inMenu: Bool
    @State private var ownItem: Bool
    @State private var variant: String
    @State private var icon: Bool

    init(settings: Settings, kind: StatsModule.StatKind, onDisplayChange: @escaping () -> Void) {
        self.settings = settings
        self.kind = kind
        self.onDisplayChange = onDisplayChange
        let id = ModuleCatalog.stats.id
        _inMenu = State(initialValue: settings.moduleBool(id: id, key: kind.showKey) ?? true)
        _ownItem = State(initialValue: settings.moduleBool(id: id, key: kind.itemKey) ?? false)
        _variant = State(initialValue: settings.moduleString(id: id, key: kind.variantKey)
            ?? kind.variants[0].id)
        _icon = State(initialValue: settings.moduleBool(id: id, key: kind.iconKey) ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dsMuted)
                    .frame(width: 16)
                Text(kind.displayName.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(Color.dsMuted)
            }
            DSToggleRow(title: "Show in dropdown", isOn: Binding(
                get: { inMenu },
                set: {
                    inMenu = $0
                    settings.setModuleBool($0, id: moduleID, key: kind.showKey)
                }))
            DSToggleRow(title: "Own menu bar item", isOn: Binding(
                get: { ownItem },
                set: {
                    ownItem = $0
                    settings.setModuleBool($0, id: moduleID, key: kind.itemKey)
                    onDisplayChange()
                }))
            if ownItem {
                HStack(spacing: 8) {
                    if kind.variants.count > 1 {
                        ForEach(kind.variants, id: \.id) { option in
                            DSChip(title: option.name, selected: variant == option.id) {
                                variant = option.id
                                settings.setModuleString(option.id, id: moduleID, key: kind.variantKey)
                                onDisplayChange()
                            }
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
        .padding(12)
        .background(
            Color.dsInk1,
            in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .strokeBorder(Color.dsLine, lineWidth: 1))
    }
}

// MARK: - Sampling

struct StatsSnapshot {
    var cpuUsage: Double = 0        // 0...1
    var memoryUsed: Double = 0      // bytes
    var memoryTotal: Double = 0     // bytes
    var swapUsed: Double = 0        // bytes
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
    var diskUsed: Double = 0        // bytes
    var diskFree: Double = 0        // bytes
    var diskTotal: Double = 0       // bytes
    var uptime: TimeInterval = 0
    var loadAverages: (Double, Double, Double) = (0, 0, 0)
}

struct BluetoothBattery {
    let name: String
    let percent: Int
}

final class StatsSampler {
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastNetBytes: (received: UInt64, sent: UInt64)?
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
            let used = Double(vmStats.active_count) + Double(vmStats.wire_count)
                + Double(vmStats.compressor_page_count)
            snapshot.memoryUsed = used * pageSize
        } else {
            Log.error("stats: host_statistics64(HOST_VM_INFO64) failed: \(vmResult)")
        }
        snapshot.memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)

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

        lastSnapshot = snapshot
        return snapshot
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
