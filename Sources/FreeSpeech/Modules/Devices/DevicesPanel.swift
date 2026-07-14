import AppKit
import SwiftUI
import FreeSpeechCore

final class DevicesStore: ObservableObject {
    @Published private(set) var batteries: [DeviceBattery] = []

    func refresh() {
        batteries = DevicesBatteryReader.read()
    }
}

final class DevicesPanelController {
    let store = DevicesStore()
    // Lets the owning module keep its status-bar glyph in sync with whatever
    // the panel just found, without a second IOKit scan.
    var onRefresh: (() -> Void)?

    private var panel: NSPanel?
    private(set) var isVisible = false
    // Local catches clicks in our own app's windows, global catches
    // everywhere else; a borderless .nonactivatingPanel never becomes key, so
    // there's no resignKey notification to hook a dismiss off of.
    private var outsideClickMonitors: [Any] = []
    private var refreshTimer: Timer?

    private static let panelSize = NSSize(width: 260, height: 300)
    private static let refreshInterval: TimeInterval = 5

    func show(belowStatusItemButton button: NSStatusBarButton) {
        if panel == nil { panel = makePanel() }
        guard let panel, let buttonWindow = button.window else { return }
        store.refresh()
        onRefresh?()

        let buttonFrame = buttonWindow.frame
        var origin = NSPoint(
            x: buttonFrame.midX - Self.panelSize.width / 2,
            y: buttonFrame.minY - Self.panelSize.height - 6)
        let screen = buttonWindow.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - Self.panelSize.width - 8)
            origin.y = max(visible.minY + 8, origin.y)
        }
        panel.setFrameOrigin(origin)

        if isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.dsFadeIn()
        }
        isVisible = true
        installOutsideClickMonitors()
        startRefreshTimer()
        Log.info("devices: panel shown (\(store.batteries.count) device(s))")
    }

    func close() {
        guard isVisible else { return }
        panel?.dsFadeOut()
        isVisible = false
        removeOutsideClickMonitors()
        stopRefreshTimer()
        Log.info("devices: panel closed")
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.store.refresh()
            self?.onRefresh?()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.dismissIfClickOutside() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            outsideClickMonitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            handler(event)
            return event
        }
        if let local { outsideClickMonitors.append(local) }
    }

    private func removeOutsideClickMonitors() {
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors.removeAll()
    }

    private func dismissIfClickOutside() {
        guard isVisible, let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        close()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)
        let root = DevicesPanelView(store: store, onClose: { [weak self] in self?.close() })
        panel.contentView = NSHostingView(rootView: root)
        return panel
    }
}

private struct DevicesPanelView: View {
    @ObservedObject var store: DevicesStore
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("DEVICES")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(Color.dsAccent)
                if !store.batteries.isEmpty {
                    Text("\(store.batteries.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dsFaint)
                }
                Spacer()
                DevicesCloseButton(action: onClose)
            }
            .background(WindowDragHandle())
            if store.batteries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.dsMuted)
                    Text("No paired devices found")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dsPaper)
                    Text("AirPods and Magic accessories show up here once paired over Bluetooth.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dsFaint)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(store.batteries.enumerated()), id: \.element.id) { index, battery in
                            DeviceBatteryRow(battery: battery)
                                .transition(.dsAppear)
                                .animation(DS.animAppear(index: index), value: store.batteries.count)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 260, height: 300)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.dsInk1.opacity(0.97)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.dsLine, lineWidth: 1.5))
    }
}

private struct DeviceBatteryRow: View {
    let battery: DeviceBattery

    private var isLow: Bool { DevicesPlan.isLow(battery.percent) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: DevicesPlan.deviceIconSymbolName(for: battery.name))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.dsMuted)
                .frame(width: 22)
            Text(battery.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Image(systemName: DevicesPlan.symbolName(percent: battery.percent))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isLow ? Color.dsAccent : Color.dsMuted)
            Text(DevicesPlan.percentLabel(battery.percent))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(isLow ? Color.dsAccent : Color.dsPaper)
                .dsValueTransition(battery.percent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            Color.dsInk2, in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous)
                .strokeBorder(Color.dsLine, lineWidth: 1))
    }
}

// A big, unmissable close target: 20pt symbol in a 30pt hit area.
private struct DevicesCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(hovering ? Color.dsPaper : Color.dsMuted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
