import AppKit
import SwiftUI
import IOKit
import FreeSpeechCore

// Stats: live machine metrics. Every section is individually toggleable, the
// refresh pace is configurable, and the menu bar item itself can show a live
// value instead of just the gauge icon. Menu sampling runs only while the menu
// is open; a live menu-bar value samples on its own timer.
final class StatsModule: NSObject, AppModule, NSMenuDelegate {
    let info = ModuleCatalog.stats

    private let settings: Settings
    private let sampler = StatsSampler()
    private var statusItem: NSStatusItem?
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
        static let showCPU = "showCPU"
        static let showMemory = "showMemory"
        static let showNetwork = "showNetwork"
        static let showDisk = "showDisk"
        static let showSystem = "showSystem"
        static let showBluetooth = "showBluetooth"
        static let menuBarStyle = "menuBarStyle"
    }

    enum MenuBarStyle: String, CaseIterable {
        case icon, cpu, memory, network

        var displayName: String {
            switch self {
            case .icon: return "Icon only"
            case .cpu: return "CPU %"
            case .memory: return "Memory %"
            case .network: return "Net down"
            }
        }
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

    private func shows(_ key: String) -> Bool {
        settings.moduleBool(id: info.id, key: key) ?? true
    }

    private var menuBarStyle: MenuBarStyle {
        settings.moduleString(id: info.id, key: Key.menuBarStyle)
            .flatMap(MenuBarStyle.init) ?? .icon
    }

    func activate() {
        active = true
        // Baseline the counters so the first menu open shows real deltas.
        sampler.sample()
        reconfigureMenuBarTimer()
    }

    func deactivate() {
        active = false
        menuTimer?.invalidate()
        menuTimer = nil
        reconfigureMenuBarTimer()
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        menuBarVisible = visible
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.toolTip = "Stats"
                item.menu = menu
                statusItem = item
            }
            statusItem?.isVisible = true
            applyMenuBarPresentation(sampleNow: true)
        } else {
            statusItem?.isVisible = false
        }
        reconfigureMenuBarTimer()
    }

    func openSettings() {
        settingsWindow.show()
    }

    func makeSettingsPane() -> AnyView {
        AnyView(StatsSettingsPane(settings: settings, onDisplayChange: { [weak self] in
            self?.applyMenuBarPresentation(sampleNow: true)
            self?.reconfigureMenuBarTimer()
        }))
    }

    // MARK: - Menu bar presentation

    // A text style keeps its own low-frequency timer so the number stays live
    // without the menu being open; icon-only costs nothing at rest.
    private func reconfigureMenuBarTimer() {
        menuBarTimer?.invalidate()
        menuBarTimer = nil
        guard active, menuBarVisible, menuBarStyle != .icon else { return }
        let timer = Timer(timeInterval: max(refreshInterval, 2.0), repeats: true) { [weak self] _ in
            self?.applyMenuBarPresentation(sampleNow: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        menuBarTimer = timer
    }

    private func applyMenuBarPresentation(sampleNow: Bool) {
        guard let button = statusItem?.button else { return }
        let style = menuBarStyle
        guard style != .icon else {
            button.image = NSImage(
                systemSymbolName: info.symbolName, accessibilityDescription: "Stats")
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        let snapshot = sampleNow ? sampler.sample() : sampler.lastSnapshot
        let text: String
        switch style {
        case .icon:
            text = ""
        case .cpu:
            text = "CPU \(StatsFormatting.percent(snapshot.cpuUsage))"
        case .memory:
            text = "MEM \(StatsFormatting.percent(snapshot.memoryUsed / max(snapshot.memoryTotal, 1)))"
        case .network:
            text = "\u{2193}\(StatsFormatting.bytesPerSecond(snapshot.downloadBytesPerSecond))"
        }
        button.image = nil
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
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

        if shows(Key.showCPU) || shows(Key.showMemory) {
            addHeader("MACHINE")
            if shows(Key.showCPU) {
                addMetric("CPU", StatsFormatting.percent(snapshot.cpuUsage))
            }
            if shows(Key.showMemory) {
                addMetric("Memory", "\(StatsFormatting.bytes(snapshot.memoryUsed)) of \(StatsFormatting.bytes(snapshot.memoryTotal)) (\(StatsFormatting.percent(snapshot.memoryUsed / max(snapshot.memoryTotal, 1))))")
                if snapshot.swapUsed > 0 {
                    addMetric("Swap", StatsFormatting.bytes(snapshot.swapUsed))
                }
            }
        }

        if shows(Key.showNetwork) {
            menu.addItem(.separator())
            addHeader("NETWORK")
            addMetric("Down", StatsFormatting.bytesPerSecond(snapshot.downloadBytesPerSecond))
            addMetric("Up", StatsFormatting.bytesPerSecond(snapshot.uploadBytesPerSecond))
        }

        if shows(Key.showDisk) {
            menu.addItem(.separator())
            addHeader("DISK")
            addMetric("Used", "\(StatsFormatting.bytes(snapshot.diskUsed)) of \(StatsFormatting.bytes(snapshot.diskTotal))")
            addMetric("Free", StatsFormatting.bytes(snapshot.diskFree))
        }

        if shows(Key.showSystem) {
            menu.addItem(.separator())
            addHeader("SYSTEM")
            addMetric("Uptime", StatsFormatting.uptime(snapshot.uptime))
            addMetric("Load", String(format: "%.2f  %.2f  %.2f",
                                     snapshot.loadAverages.0, snapshot.loadAverages.1,
                                     snapshot.loadAverages.2))
        }

        if shows(Key.showBluetooth) {
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
    @State private var style: StatsModule.MenuBarStyle

    init(settings: Settings, onDisplayChange: @escaping () -> Void) {
        self.settings = settings
        self.onDisplayChange = onDisplayChange
        let id = ModuleCatalog.stats.id
        _refresh = State(initialValue: settings.moduleDouble(id: id, key: StatsModule.Key.refreshInterval) ?? 1.0)
        _style = State(initialValue: settings.moduleString(id: id, key: StatsModule.Key.menuBarStyle)
            .flatMap(StatsModule.MenuBarStyle.init) ?? .icon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                DSSectionLabel("Menu bar shows")
                HStack(spacing: 8) {
                    ForEach(StatsModule.MenuBarStyle.allCases, id: \.rawValue) { value in
                        DSChip(title: value.displayName, selected: style == value) {
                            style = value
                            settings.setModuleString(value.rawValue, id: moduleID, key: StatsModule.Key.menuBarStyle)
                            onDisplayChange()
                        }
                    }
                }
                Text("A live value samples in the background (2s minimum); the icon costs nothing at rest.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }

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
            }

            VStack(alignment: .leading, spacing: 10) {
                DSSectionLabel("Sections")
                toggle("CPU", StatsModule.Key.showCPU)
                toggle("Memory and swap", StatsModule.Key.showMemory)
                toggle("Network throughput", StatsModule.Key.showNetwork)
                toggle("Disk usage", StatsModule.Key.showDisk)
                toggle("Uptime and load", StatsModule.Key.showSystem)
                toggle("Bluetooth battery", StatsModule.Key.showBluetooth)
            }
        }
    }

    private func toggle(_ title: String, _ key: String) -> some View {
        DSToggleRow(
            title: title,
            isOn: Binding(
                get: { settings.moduleBool(id: moduleID, key: key) ?? true },
                set: { settings.setModuleBool($0, id: moduleID, key: key) }))
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
