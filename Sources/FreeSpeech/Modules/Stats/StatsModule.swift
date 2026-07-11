import AppKit
import SwiftUI
import IOKit
import FreeSpeechCore

// Stats: live machine metrics in a menu that refreshes while open. Sampling is
// cheap (mach counters + getifaddrs) so it only runs when the menu is visible.
final class StatsModule: NSObject, AppModule, NSMenuDelegate {
    let info = ModuleCatalog.stats

    private let settings: Settings
    private let sampler = StatsSampler()
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private let menu = NSMenu()

    init(settings: Settings) {
        self.settings = settings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func activate() {
        // Baseline the counters so the first menu open shows real deltas.
        sampler.sample()
    }

    func deactivate() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(
                    systemSymbolName: info.symbolName, accessibilityDescription: "Stats")
                item.button?.toolTip = "Stats"
                item.menu = menu
                statusItem = item
            }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    func makeSettingsPane() -> AnyView {
        AnyView(Text("CPU, memory, and network refresh once a second while the menu is open. Bluetooth battery levels come from paired devices that report them (Magic keyboards, mice, trackpads, some headphones).")
            .font(.system(size: 11))
            .foregroundStyle(Color.dsMuted)
            .fixedSize(horizontal: false, vertical: true))
    }

    // MARK: - Menu lifecycle

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
        // .common mode keeps the timer firing during menu tracking.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.rebuild()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func rebuild() {
        let snapshot = sampler.sample()
        menu.removeAllItems()

        addHeader("MACHINE")
        addMetric("CPU", StatsFormatting.percent(snapshot.cpuUsage))
        addMetric("Memory", "\(StatsFormatting.bytes(snapshot.memoryUsed)) of \(StatsFormatting.bytes(snapshot.memoryTotal)) (\(StatsFormatting.percent(snapshot.memoryUsed / max(snapshot.memoryTotal, 1))))")
        addMetric("Net down", StatsFormatting.bytesPerSecond(snapshot.downloadBytesPerSecond))
        addMetric("Net up", StatsFormatting.bytesPerSecond(snapshot.uploadBytesPerSecond))

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

// MARK: - Sampling

struct StatsSnapshot {
    var cpuUsage: Double = 0        // 0...1
    var memoryUsed: Double = 0      // bytes
    var memoryTotal: Double = 0     // bytes
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
}

struct BluetoothBattery {
    let name: String
    let percent: Int
}

final class StatsSampler {
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastNetBytes: (received: UInt64, sent: UInt64)?
    private var lastSampleTime: CFAbsoluteTime?

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
