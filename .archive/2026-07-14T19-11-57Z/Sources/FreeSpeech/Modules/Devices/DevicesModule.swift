import AppKit
import SwiftUI
import IOKit
import FreeSpeechCore

// Devices: menu bar battery readout for paired Bluetooth accessories.
// Clicking the status item shows a popup that dismisses on any outside
// click; no hotkey, no settings pane (nothing here needs configuring).
final class DevicesModule: NSObject, AppModule {
    let info = ModuleCatalog.devices

    private var statusItem: NSStatusItem?
    private var active = false
    private var menuBarVisible = false
    private let panelController: DevicesPanelController

    override init() {
        panelController = DevicesPanelController()
        super.init()
        panelController.onRefresh = { [weak self] in self?.refreshGlyph() }
    }

    func activate() {
        active = true
        applyMenuBarConfiguration()
    }

    func deactivate() {
        active = false
        panelController.close()
        applyMenuBarConfiguration()
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        menuBarVisible = visible
        applyMenuBarConfiguration()
    }

    var settingsStyle: ModuleSettingsStyle { .none }
    func makeSettingsPane() -> AnyView { AnyView(EmptyView()) }

    private func applyMenuBarConfiguration() {
        let shouldShow = active && menuBarVisible
        guard shouldShow else {
            statusItem?.isVisible = false
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.toolTip = "Devices: click for paired accessory battery"
            item.button?.target = self
            item.button?.action = #selector(statusItemTapped)
            statusItem = item
        }
        statusItem?.isVisible = true
        refreshGlyph()
    }

    @objc private func statusItemTapped() {
        guard let button = statusItem?.button else { return }
        if panelController.isVisible {
            panelController.close()
        } else {
            panelController.show(belowStatusItemButton: button)
        }
    }

    private func refreshGlyph() {
        guard let button = statusItem?.button else { return }
        let batteries = DevicesBatteryReader.read()
        button.image = NSImage(
            systemSymbolName: DevicesPlan.statusItemSymbolName(for: batteries),
            accessibilityDescription: "Devices")
    }
}

// IOKit scan for HID-over-Bluetooth accessory batteries (AirPods, Magic
// Mouse/Keyboard/Trackpad, and similar). There is no public API for other
// iCloud devices' battery (iPhone/iPad/Watch continuity) — only what shows
// up here.
enum DevicesBatteryReader {
    static func read() -> [DeviceBattery] {
        var results: [DeviceBattery] = []
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            Log.error("devices: IOServiceGetMatchingServices failed: \(result)")
            return []
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let percent = registryProperty(service, "BatteryPercent") as? Int else { continue }
            let name = (registryProperty(service, "Product") as? String) ?? "Bluetooth device"
            results.append(DeviceBattery(name: name, percent: percent))
        }
        return DevicesPlan.sorted(results)
    }

    private static func registryProperty(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
