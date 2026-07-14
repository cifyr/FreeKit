import AppKit
import SwiftUI
import FreeSpeechCore

// Shelf: wiggle a drag side to side and a floating shelf pops up under the
// cursor; park files there, drag them back out anywhere, close with the X.
// The shake gesture is the primary way in; the optional menu bar icon is a
// way to reopen a shelf that still has items on it, or clear it. The shake
// math lives in Core's ShelfPlan.
final class ShelfModule: NSObject, AppModule, NSMenuDelegate {
    let info = ModuleCatalog.shelf

    private let settings: Settings
    private var mouseMonitor: Any?
    private var detector: ShakeDetector
    private var dragSessionActive = false
    private var lastDragChangeCount = 0
    private var statusItem: NSStatusItem?
    private let panelController: ShelfPanelController
    private let paneModel = ShelfPaneModel()

    enum Key {
        static let sensitivity = "sensitivity"
        static let keepOnClose = "keepOnClose"
        static let iconView = "iconView"
    }

    init(settings: Settings) {
        self.settings = settings
        panelController = ShelfPanelController(settings: settings, moduleID: ModuleCatalog.shelf.id)
        detector = ShakeDetector(config: ShelfPlan.config(forSensitivity: ShelfPlan.defaultSensitivity))
        super.init()
    }

    // 0 (Low) ... 1 (High) dial; the settings slider is right there for
    // anyone who wants it easier or stricter.
    private var sensitivity: Double {
        settings.moduleDouble(id: info.id, key: Key.sensitivity) ?? ShelfPlan.defaultSensitivity
    }

    private var keepOnClose: Bool {
        settings.moduleBool(id: info.id, key: Key.keepOnClose) ?? false
    }

    // MARK: - AppModule

    func activate() {
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
        if mouseMonitor == nil {
            // Global monitors ride the same Accessibility grant as the event
            // tap; without it they silently never fire, so note that loudly.
            if !Permissions.accessibilityTrusted(promptIfNeeded: false) {
                Log.error("shelf: accessibility not granted, shake detection will not work")
            }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.handleGlobalMouse(event)
            }
        }
        paneModel.module = self
        Log.info("shelf: activated, sensitivity=\(String(format: "%.2f", sensitivity))")
    }

    func deactivate() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        panelController.keepItemsOnClose = false
        panelController.close()
        panelController.store.clear()
        Log.info("shelf: deactivated")
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(
                    systemSymbolName: info.symbolName, accessibilityDescription: "Shelf")
                item.button?.toolTip = "Shelf"
                let menu = NSMenu()
                menu.delegate = self
                item.menu = menu
                statusItem = item
            }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    var settingsPopupSize: NSSize { NSSize(width: 560, height: 480) }

    func makeSettingsPane() -> AnyView {
        paneModel.module = self
        return AnyView(ShelfSettingsPane(model: paneModel, settings: settings))
    }

    // MARK: - Shake detection

    private func handleGlobalMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp:
            dragSessionActive = false
            detector.reset()
        case .leftMouseDragged:
            let dragCount = NSPasteboard(name: .drag).changeCount
            if dragCount != lastDragChangeCount {
                // Fresh drag pasteboard = a new drag session just started.
                lastDragChangeCount = dragCount
                dragSessionActive = true
                detector = ShakeDetector(config: ShelfPlan.config(forSensitivity: sensitivity))
            }
            guard dragSessionActive, !panelController.isVisible else { return }
            let location = NSEvent.mouseLocation
            if detector.addSample(x: location.x, time: event.timestamp) {
                Log.info("shelf: shake detected at (\(Int(location.x)), \(Int(location.y)))")
                showShelf(near: location)
            }
        default:
            break
        }
    }

    func showShelf(near point: NSPoint) {
        panelController.keepItemsOnClose = keepOnClose
        panelController.show(near: point)
    }

    // Entry point for other modules bridging files in directly (e.g. dragging onto the
    // notch) rather than the shake gesture.
    func addToShelf(_ urls: [URL], near point: NSPoint) {
        panelController.keepItemsOnClose = keepOnClose
        panelController.store.add(urls)
        panelController.show(near: point)
    }

    func clearShelf() {
        panelController.store.clear()
    }

    var itemCount: Int { panelController.store.items.count }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let count = itemCount
        let show = NSMenuItem(
            title: count > 0 ? "Show Shelf (\(count))" : "Show Shelf",
            action: #selector(showShelfFromMenu), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        if count > 0 {
            let clear = NSMenuItem(title: "Clear Shelf", action: #selector(clearShelfFromMenu), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Shelf Settings\u{2026}", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    @objc private func showShelfFromMenu() {
        guard let button = statusItem?.button, let window = button.window else {
            showShelf(near: NSEvent.mouseLocation)
            return
        }
        let screenFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        showShelf(near: NSPoint(x: screenFrame.midX, y: screenFrame.minY))
    }

    @objc private func clearShelfFromMenu() {
        clearShelf()
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }
}

// MARK: - Settings pane

final class ShelfPaneModel: ObservableObject {
    weak var module: ShelfModule?
}

private struct ShelfSettingsPane: View {
    @ObservedObject var model: ShelfPaneModel
    let settings: Settings

    private let moduleID = ModuleCatalog.shelf.id
    @State private var sensitivity: Double
    @State private var keepOnClose: Bool

    init(model: ShelfPaneModel, settings: Settings) {
        self.model = model
        self.settings = settings
        let id = ModuleCatalog.shelf.id
        _sensitivity = State(initialValue: settings.moduleDouble(id: id, key: ShelfModule.Key.sensitivity)
            ?? ShelfPlan.defaultSensitivity)
        _keepOnClose = State(initialValue: settings.moduleBool(id: id, key: ShelfModule.Key.keepOnClose) ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSettingsCard(title: "Shake") {
                HStack(spacing: 10) {
                    Text("Low")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                    Slider(value: Binding(
                        get: { sensitivity },
                        set: {
                            sensitivity = $0
                            settings.setModuleDouble($0, id: moduleID, key: ShelfModule.Key.sensitivity)
                        }), in: 0...1)
                        .tint(Color.dsAccent)
                        .dsNoWindowDrag()
                    Text("High")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
                Text("Wiggle side to side while dragging and the shelf appears under the cursor. Any drag can summon it; the shelf itself only accepts files.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }

            DSSettingsCard(title: "Shelf") {
                DSToggleRow(
                    title: "Keep items when closing",
                    caption: "Off means the X forgets the parked list. Files themselves are never moved or deleted \u{2014} the shelf only holds references.",
                    isOn: Binding(
                        get: { keepOnClose },
                        set: {
                            keepOnClose = $0
                            settings.setModuleBool($0, id: moduleID, key: ShelfModule.Key.keepOnClose)
                        }))
                HStack(spacing: 8) {
                    Button("Show Shelf Now") {
                        model.module?.showShelf(near: NSEvent.mouseLocation)
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button("Clear Shelf") { model.module?.clearShelf() }
                        .buttonStyle(GhostButtonStyle())
                    Spacer()
                }
            }
        }
    }
}
