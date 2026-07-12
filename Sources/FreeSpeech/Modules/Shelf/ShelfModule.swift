import AppKit
import Combine
import SwiftUI
import FreeSpeechCore

// Shelf: wiggle a drag side to side and a floating shelf pops up under the
// cursor; park files there, drag them back out anywhere, close with the X.
// The shake gesture math lives in Core's ShelfPlan.
final class ShelfModule: NSObject, AppModule, NSMenuDelegate {
    let info = ModuleCatalog.shelf

    private let settings: Settings
    private var statusItem: NSStatusItem?
    private var mouseMonitor: Any?
    private var detector: ShakeDetector
    private var dragSessionActive = false
    private var lastDragChangeCount = 0
    private var storeSubscription: AnyCancellable?
    private let panelController = ShelfPanelController()
    private let paneModel = ShelfPaneModel()
    private lazy var settingsWindow = ModuleSettingsWindowController(
        info: info,
        contentSize: NSSize(width: 560, height: 480)
    ) { [weak self] in
        self?.makeSettingsPane() ?? AnyView(EmptyView())
    }

    enum Key {
        static let sensitivity = "sensitivity"
        static let keepOnClose = "keepOnClose"
    }

    init(settings: Settings) {
        self.settings = settings
        detector = ShakeDetector(config: ShelfPlan.Sensitivity.medium.config)
        super.init()
    }

    private var sensitivity: ShelfPlan.Sensitivity {
        settings.moduleString(id: info.id, key: Key.sensitivity)
            .flatMap(ShelfPlan.Sensitivity.init) ?? .medium
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
        panelController.onVisibilityChange = { [weak self] in self?.updateStatusIcon() }
        storeSubscription = panelController.store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                // objectWillChange fires before the array mutates; icon reads
                // the store, so refresh one runloop turn later.
                DispatchQueue.main.async { self?.updateStatusIcon() }
            }
        paneModel.module = self
        Log.info("shelf: activated, sensitivity=\(sensitivity.rawValue)")
    }

    func deactivate() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        storeSubscription = nil
        panelController.keepItemsOnClose = false
        panelController.close()
        panelController.store.clear()
        Log.info("shelf: deactivated")
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.toolTip = "Shelf \u{2014} wiggle a drag to park files"
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

    func openSettings() {
        settingsWindow.show()
    }

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
                detector = ShakeDetector(config: sensitivity.config)
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

    func clearShelf() {
        panelController.store.clear()
        updateStatusIcon()
    }

    var itemCount: Int { panelController.store.items.count }

    // MARK: - Status item

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let count = itemCount
        button.image = NSImage(
            systemSymbolName: count > 0 ? "tray.full" : "tray",
            accessibilityDescription: count > 0 ? "Shelf holding \(count) file(s)" : "Shelf empty")
        // Accent tint = live activity, matching the suite's use of red for "hot".
        button.contentTintColor = panelController.isVisible ? DS.accent : nil
        button.attributedTitle = NSAttributedString(
            string: count > 0 ? " \(count)" : "",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let count = itemCount
        let statusTitle = count > 0
            ? "\(count) file\(count == 1 ? "" : "s") parked"
            : "Wiggle a drag to open the shelf"
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let open = NSMenuItem(
            title: panelController.isVisible ? "Hide Shelf" : "Show Shelf",
            action: #selector(menuToggleShelf), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let clear = NSMenuItem(
            title: "Clear Shelf", action: #selector(menuClear), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = count > 0
        menu.addItem(clear)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Shelf Settings\u{2026}", action: #selector(menuOpenSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    @objc private func menuToggleShelf() {
        if panelController.isVisible {
            panelController.close()
        } else {
            showShelf(near: NSEvent.mouseLocation)
        }
    }

    @objc private func menuClear() {
        clearShelf()
    }

    @objc private func menuOpenSettings() {
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
    @State private var sensitivity: ShelfPlan.Sensitivity
    @State private var keepOnClose: Bool

    init(model: ShelfPaneModel, settings: Settings) {
        self.model = model
        self.settings = settings
        let id = ModuleCatalog.shelf.id
        _sensitivity = State(initialValue: settings.moduleString(id: id, key: ShelfModule.Key.sensitivity)
            .flatMap(ShelfPlan.Sensitivity.init) ?? .medium)
        _keepOnClose = State(initialValue: settings.moduleBool(id: id, key: ShelfModule.Key.keepOnClose) ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSettingsCard(title: "Shake") {
                HStack(spacing: 8) {
                    Text("Sensitivity")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                        .frame(width: 80, alignment: .leading)
                    ForEach(ShelfPlan.Sensitivity.allCases, id: \.rawValue) { value in
                        DSChip(title: value.displayName, selected: sensitivity == value) {
                            sensitivity = value
                            settings.setModuleString(value.rawValue, id: moduleID,
                                                     key: ShelfModule.Key.sensitivity)
                        }
                        .fixedSize()
                    }
                    Spacer()
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
