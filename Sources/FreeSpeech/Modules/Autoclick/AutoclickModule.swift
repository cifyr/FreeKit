import AppKit
import SwiftUI
import FreeSpeechCore

// Tap: fixed-interval synthetic clicks at the cursor or a captured point.
// Scheduling math lives in Core's AutoclickPlan; this layer posts the CGEvents.
final class AutoclickModule: NSObject, AppModule, NSMenuDelegate {
    let info = ModuleCatalog.autoclicker

    private let settings: Settings
    private let hub: EventTapHub
    private let permissionCoach: PermissionCoachController

    private var hotkeyToken: EventTapHub.HotkeyToken?
    private var statusItem: NSStatusItem?
    private var timer: DispatchSourceTimer?
    private var clicksPerformed = 0
    private var lastPostedPosition: CGPoint?
    private let paneModel = AutoclickPaneModel()
    private lazy var settingsWindow = ModuleSettingsWindowController(info: info) { [weak self] in
        self?.makeSettingsPane() ?? AnyView(EmptyView())
    }

    enum Key {
        static let interval = "interval"
        static let maxClicks = "maxClicks"  // 0 = until stopped
        static let button = "button"
        static let target = "target"
        static let clickType = "clickType"
        static let stopOnMove = "stopOnMove"
        static let pointX = "pointX"
        static let pointY = "pointY"
    }

    // Ctrl+Opt+T: "tap", mirrors Notebook's Ctrl+Opt namespace.
    static let defaultHotkey = HotkeyPreset.custom(
        keyCode: 17, modifiers: [.control, .option])

    init(settings: Settings, hub: EventTapHub, permissionCoach: PermissionCoachController) {
        self.settings = settings
        self.hub = hub
        self.permissionCoach = permissionCoach
        super.init()
    }

    private var hotkey: HotkeyPreset {
        settings.moduleHotkey(id: info.id, defaultPreset: Self.defaultHotkey)
    }

    static func currentPlan(settings: Settings) -> AutoclickPlan {
        let id = ModuleCatalog.autoclicker.id
        return AutoclickPlan(
            interval: settings.moduleDouble(id: id, key: Key.interval) ?? 0.1,
            maxClicks: (settings.moduleInt(id: id, key: Key.maxClicks)).flatMap { $0 > 0 ? $0 : nil },
            button: settings.moduleString(id: id, key: Key.button)
                .flatMap(AutoclickPlan.Button.init) ?? .left,
            target: settings.moduleString(id: id, key: Key.target)
                .flatMap(AutoclickPlan.Target.init) ?? .cursor,
            clickType: settings.moduleString(id: id, key: Key.clickType)
                .flatMap(AutoclickPlan.ClickType.init) ?? .single,
            stopOnCursorMove: settings.moduleBool(id: id, key: Key.stopOnMove) ?? true)
    }

    private var fixedPoint: CGPoint {
        CGPoint(
            x: settings.moduleDouble(id: info.id, key: Key.pointX) ?? 0,
            y: settings.moduleDouble(id: info.id, key: Key.pointY) ?? 0)
    }

    var isRunning: Bool { timer != nil }

    func activate() {
        if hotkeyToken == nil {
            hotkeyToken = hub.register(preset: hotkey, label: "autoclick.toggle") { [weak self] direction in
                guard direction == .down else { return }
                self?.toggleClicking()
            }
        }
        paneModel.module = self
    }

    func deactivate() {
        stopClicking()
        if let hotkeyToken { hub.unregister(hotkeyToken) }
        hotkeyToken = nil
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.toolTip = "Tap autoclicker"
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
        return AnyView(AutoclickSettingsPane(model: paneModel, settings: settings))
    }

    // MARK: - Clicking

    func toggleClicking() {
        isRunning ? stopClicking() : startClicking()
    }

    private func startClicking() {
        guard !isRunning else { return }
        // Synthetic events need Accessibility; usually granted already for the
        // shared tap, but the coach covers a fresh install.
        guard Permissions.accessibilityTrusted(promptIfNeeded: true) else {
            permissionCoach.show(.accessibility)
            return
        }
        let plan = Self.currentPlan(settings: settings)
        clicksPerformed = 0
        lastPostedPosition = nil
        Log.info("autoclick: start interval=\(plan.interval)s max=\(plan.maxClicks.map(String.init) ?? "unlimited") button=\(plan.button.rawValue) type=\(plan.clickType.rawValue) target=\(plan.target.rawValue)")
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: plan.interval)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if plan.isComplete(afterClicks: self.clicksPerformed) {
                Log.info("autoclick: reached \(self.clicksPerformed) clicks, stopping")
                self.stopClicking()
                return
            }
            // Fixed-point safety valve: the user grabbing the mouse means
            // "stop", not "fight me for the cursor".
            if plan.target == .fixedPoint, plan.stopOnCursorMove,
               let last = self.lastPostedPosition,
               let current = CGEvent(source: nil)?.location,
               abs(current.x - last.x) > 5 || abs(current.y - last.y) > 5 {
                Log.info("autoclick: cursor moved away from fixed point, stopping")
                self.stopClicking()
                return
            }
            self.postClick(plan: plan)
            self.clicksPerformed += 1
        }
        timer = source
        source.resume()
        updateStatusIcon()
        paneModel.objectWillChange.send()
    }

    private func stopClicking() {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        Log.info("autoclick: stopped after \(clicksPerformed) clicks")
        updateStatusIcon()
        paneModel.objectWillChange.send()
    }

    private func postClick(plan: AutoclickPlan) {
        let position: CGPoint
        switch plan.target {
        case .cursor:
            // CGEvent(source: nil) reads the current hardware cursor location
            // in the same top-left coordinate space clicks are posted in.
            position = CGEvent(source: nil)?.location ?? .zero
        case .fixedPoint:
            position = fixedPoint
        }
        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
            plan.button == .left
            ? (.leftMouseDown, .leftMouseUp, .left)
            : (.rightMouseDown, .rightMouseUp, .right)
        // Double-clicks are two pairs with an increasing click state, which is
        // how apps distinguish a real double-click from two fast singles.
        for press in 1...plan.clickType.pressesPerTick {
            guard let down = CGEvent(
                    mouseEventSource: nil, mouseType: downType,
                    mouseCursorPosition: position, mouseButton: button),
                  let up = CGEvent(
                    mouseEventSource: nil, mouseType: upType,
                    mouseCursorPosition: position, mouseButton: button) else {
                Log.error("autoclick: failed to build click events at \(position)")
                stopClicking()
                return
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(press))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(press))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        lastPostedPosition = position
    }

    // NSEvent.mouseLocation is bottom-left origin; CGEvent posting is top-left.
    static func currentCursorTopLeft() -> CGPoint {
        let loc = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: loc.x, y: screenHeight - loc.y)
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: isRunning ? "cursorarrow.click.badge.clock" : "cursorarrow.click.2",
            accessibilityDescription: isRunning ? "Tap clicking" : "Tap idle")
        // Accent tint = live activity, matching the suite's use of red for "hot".
        button.contentTintColor = isRunning ? DS.accent : nil
        button.toolTip = isRunning ? "Tap: clicking (hotkey stops)" : "Tap autoclicker"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let plan = Self.currentPlan(settings: settings)
        let status = NSMenuItem(
            title: isRunning
                ? "Clicking — \(clicksPerformed) so far"
                : String(format: "Idle — %.2fs interval, %@", plan.interval,
                         plan.maxClicks.map { "\($0) clicks" } ?? "until stopped"),
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let toggle = NSMenuItem(
            title: isRunning ? "Stop Clicking" : "Start Clicking (\(hotkey.displayName))",
            action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Tap Settings\u{2026}", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    @objc private func menuToggle() {
        // Menu-initiated starts race the menu closing; defer one runloop turn so
        // the first click never lands on our own menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.toggleClicking()
        }
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }
}

// MARK: - Settings pane

// Bridges the module to SwiftUI so Start/Stop state and captured points refresh.
final class AutoclickPaneModel: ObservableObject {
    weak var module: AutoclickModule?
    @Published var captureCountdown: Int?
}

private struct AutoclickSettingsPane: View {
    @ObservedObject var model: AutoclickPaneModel
    let settings: Settings

    private let moduleID = ModuleCatalog.autoclicker.id
    @State private var interval: Double
    @State private var maxClicks: Double
    @State private var button: AutoclickPlan.Button
    @State private var target: AutoclickPlan.Target
    @State private var clickType: AutoclickPlan.ClickType
    @State private var stopOnMove: Bool

    init(model: AutoclickPaneModel, settings: Settings) {
        self.model = model
        self.settings = settings
        let id = ModuleCatalog.autoclicker.id
        _interval = State(initialValue: settings.moduleDouble(id: id, key: AutoclickModule.Key.interval) ?? 0.1)
        _maxClicks = State(initialValue: Double(settings.moduleInt(id: id, key: AutoclickModule.Key.maxClicks) ?? 0))
        _button = State(initialValue: settings.moduleString(id: id, key: AutoclickModule.Key.button)
            .flatMap(AutoclickPlan.Button.init) ?? .left)
        _target = State(initialValue: settings.moduleString(id: id, key: AutoclickModule.Key.target)
            .flatMap(AutoclickPlan.Target.init) ?? .cursor)
        _clickType = State(initialValue: settings.moduleString(id: id, key: AutoclickModule.Key.clickType)
            .flatMap(AutoclickPlan.ClickType.init) ?? .single)
        _stopOnMove = State(initialValue: settings.moduleBool(id: id, key: AutoclickModule.Key.stopOnMove) ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HotkeyRecorderButton(
                label: "Start / stop",
                preset: settings.moduleHotkey(
                    id: moduleID, defaultPreset: AutoclickModule.defaultHotkey),
                onChange: { settings.setModuleHotkey($0, id: moduleID) })

            VStack(alignment: .leading, spacing: 8) {
                DSSectionLabel("Interval")
                HStack(spacing: 8) {
                    ForEach([0.05, 0.1, 0.25, 0.5, 1.0], id: \.self) { value in
                        DSChip(title: chipTitle(value), selected: abs(interval - value) < 0.0001) {
                            setInterval(value)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("Custom")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dsMuted)
                    DSNumberField(
                        placeholder: "sec",
                        value: $interval,
                        range: AutoclickPlan.minInterval...AutoclickPlan.maxInterval,
                        fractionDigits: 3,
                        onCommit: { setInterval($0) })
                    Text(String(format: "seconds between clicks (= %.1f clicks/sec)", 1.0 / max(interval, 0.001)))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                DSSectionLabel("Stop after")
                HStack(spacing: 8) {
                    ForEach([0, 10, 100, 1000], id: \.self) { value in
                        DSChip(title: value == 0 ? "Until stopped" : "\(value)",
                               selected: Int(maxClicks) == value) {
                            setMaxClicks(Double(value))
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("Custom")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dsMuted)
                    DSNumberField(
                        placeholder: "count",
                        value: $maxClicks,
                        range: 0...1_000_000,
                        fractionDigits: 0,
                        onCommit: { setMaxClicks($0) })
                    Text("clicks, 0 = until stopped")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    DSSectionLabel("Click")
                    HStack(spacing: 8) {
                        ForEach(AutoclickPlan.ClickType.allCases, id: \.rawValue) { value in
                            DSChip(title: value.displayName, selected: clickType == value) {
                                clickType = value
                                settings.setModuleString(value.rawValue, id: moduleID, key: AutoclickModule.Key.clickType)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    DSSectionLabel("Button")
                    HStack(spacing: 8) {
                        ForEach(AutoclickPlan.Button.allCases, id: \.rawValue) { value in
                            DSChip(title: value.displayName, selected: button == value) {
                                button = value
                                settings.setModuleString(value.rawValue, id: moduleID, key: AutoclickModule.Key.button)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                DSSectionLabel("Where")
                HStack(spacing: 8) {
                    ForEach(AutoclickPlan.Target.allCases, id: \.rawValue) { value in
                        DSChip(title: value.displayName, selected: target == value) {
                            target = value
                            settings.setModuleString(value.rawValue, id: moduleID, key: AutoclickModule.Key.target)
                        }
                    }
                }
                if target == .fixedPoint {
                    HStack(spacing: 10) {
                        Button(captureButtonTitle) { beginCapture() }
                            .buttonStyle(GhostButtonStyle())
                            .disabled(model.captureCountdown != nil)
                        Text(pointDescription)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.dsMuted)
                    }
                    DSToggleRow(
                        title: "Stop when I move the mouse",
                        caption: "Grabbing the cursor cancels the run instead of fighting it.",
                        isOn: Binding(
                            get: { stopOnMove },
                            set: {
                                stopOnMove = $0
                                settings.setModuleBool($0, id: moduleID, key: AutoclickModule.Key.stopOnMove)
                            }))
                }
            }
        }
    }

    private func setInterval(_ value: Double) {
        interval = value
        settings.setModuleDouble(value, id: moduleID, key: AutoclickModule.Key.interval)
    }

    private func setMaxClicks(_ value: Double) {
        maxClicks = value.rounded()
        settings.setModuleInt(Int(maxClicks), id: moduleID, key: AutoclickModule.Key.maxClicks)
    }

    private var captureButtonTitle: String {
        if let n = model.captureCountdown { return "Capturing in \(n)\u{2026}" }
        return "Capture Point (3s)"
    }

    private var pointDescription: String {
        let x = settings.moduleDouble(id: moduleID, key: AutoclickModule.Key.pointX)
        let y = settings.moduleDouble(id: moduleID, key: AutoclickModule.Key.pointY)
        guard let x, let y else { return "No point captured yet" }
        return String(format: "(%.0f, %.0f)", x, y)
    }

    // Countdown capture: move the mouse where clicks should land; the position
    // is sampled when the count hits zero.
    private func beginCapture() {
        model.captureCountdown = 3
        tick()
    }

    private func tick() {
        guard let n = model.captureCountdown else { return }
        if n == 0 {
            let point = AutoclickModule.currentCursorTopLeft()
            settings.setModuleDouble(Double(point.x), id: moduleID, key: AutoclickModule.Key.pointX)
            settings.setModuleDouble(Double(point.y), id: moduleID, key: AutoclickModule.Key.pointY)
            Log.info("autoclick: captured fixed point (\(Int(point.x)), \(Int(point.y)))")
            model.captureCountdown = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            model.captureCountdown = n - 1
            tick()
        }
    }

    private func chipTitle(_ interval: Double) -> String {
        interval < 1 ? String(format: "%.0f/s", 1.0 / interval) : String(format: "%.0fs", interval)
    }
}
