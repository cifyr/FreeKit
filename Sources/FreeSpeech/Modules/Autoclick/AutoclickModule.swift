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
    private let macroRunner = MacroRunner()
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
        static let mode = "mode"    // simple | macro
        static let macro = "macro"  // Macro JSON
    }

    enum Mode: String, CaseIterable {
        case simple, macro

        var displayName: String {
            switch self {
            case .simple: return "Autoclick"
            case .macro: return "Macro"
            }
        }
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

    var isRunning: Bool { timer != nil || macroRunner.isRunning }

    var mode: Mode {
        settings.moduleString(id: info.id, key: Key.mode).flatMap(Mode.init) ?? .simple
    }

    var storedMacro: Macro {
        settings.moduleString(id: info.id, key: Key.macro)
            .flatMap(Macro.decode) ?? Macro()
    }

    func storeMacro(_ macro: Macro) {
        settings.setModuleString(macro.encodedJSON(), id: info.id, key: Key.macro)
    }

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
        if isRunning {
            stopClicking()
            return
        }
        // Synthetic events need Accessibility; usually granted already for the
        // shared tap, but the coach covers a fresh install.
        guard Permissions.accessibilityTrusted(promptIfNeeded: true) else {
            permissionCoach.show(.accessibility)
            return
        }
        switch mode {
        case .simple:
            startClicking()
        case .macro:
            let macro = storedMacro
            guard !macro.steps.isEmpty else {
                Log.error("macro: start requested with no steps recorded")
                return
            }
            macroRunner.onStateChange = { [weak self] in
                self?.updateStatusIcon()
                self?.paneModel.objectWillChange.send()
            }
            macroRunner.start(macro: macro)
        }
    }

    private func startClicking() {
        guard timer == nil else { return }
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
        if macroRunner.isRunning {
            macroRunner.stop()
        }
        if let timer {
            timer.cancel()
            self.timer = nil
            Log.info("autoclick: stopped after \(clicksPerformed) clicks")
        }
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
        let statusTitle: String
        switch (mode, isRunning) {
        case (.simple, true):
            statusTitle = "Clicking — \(clicksPerformed) so far"
        case (.simple, false):
            let plan = Self.currentPlan(settings: settings)
            statusTitle = String(
                format: "Idle — %.2fs interval, %@", plan.interval,
                plan.maxClicks.map { "\($0) clicks" } ?? "until stopped")
        case (.macro, true):
            statusTitle = "Macro running — pass \(macroRunner.runsCompleted + 1)"
        case (.macro, false):
            statusTitle = "Macro — \(storedMacro.steps.count) steps"
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let verb = mode == .macro ? "Macro" : "Clicking"
        let toggle = NSMenuItem(
            title: isRunning ? "Stop \(verb)" : "Start \(verb) (\(hotkey.displayName))",
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

// MARK: - Macro execution

// Interprets a Core Macro: clicks, key chords, and waits chained with
// asyncAfter on the main queue so stop() can cut in between any two steps.
final class MacroRunner {
    private(set) var isRunning = false
    private(set) var runsCompleted = 0
    private var generation = 0
    var onStateChange: (() -> Void)?

    func start(macro: Macro) {
        guard !isRunning, !macro.steps.isEmpty else { return }
        isRunning = true
        runsCompleted = 0
        generation += 1
        Log.info("macro: start — \(macro.steps.count) steps, repeat=\(macro.repeatCount == 0 ? "until stopped" : String(macro.repeatCount))")
        run(macro: macro, stepIndex: 0, generation: generation)
        onStateChange?()
    }

    func stop() {
        guard isRunning else { return }
        // Bumping the generation orphans any queued asyncAfter continuation.
        generation += 1
        isRunning = false
        Log.info("macro: stopped after \(runsCompleted) completed passes")
        onStateChange?()
    }

    private func run(macro: Macro, stepIndex: Int, generation: Int) {
        guard isRunning, generation == self.generation else { return }
        if stepIndex >= macro.steps.count {
            runsCompleted += 1
            if macro.isComplete(afterRuns: runsCompleted) {
                Log.info("macro: completed \(runsCompleted) passes")
                isRunning = false
                onStateChange?()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + macro.interval) { [weak self] in
                self?.run(macro: macro, stepIndex: 0, generation: generation)
            }
            return
        }

        let step = macro.steps[stepIndex]
        var delay = macro.stepGap
        switch step {
        case .click(let button, let type, let x, let y):
            let position: CGPoint
            if let x, let y {
                position = CGPoint(x: x, y: y)
            } else {
                position = CGEvent(source: nil)?.location ?? .zero
            }
            Self.postClick(button: button, type: type, at: position)
        case .key(let keyCode, let modifiers):
            Self.postKey(keyCode: keyCode, modifiers: modifiers)
        case .wait(let seconds):
            delay = seconds
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.run(macro: macro, stepIndex: stepIndex + 1, generation: generation)
        }
    }

    static func postClick(button: AutoclickPlan.Button, type: AutoclickPlan.ClickType,
                          at position: CGPoint) {
        let (downType, upType, mouseButton): (CGEventType, CGEventType, CGMouseButton) =
            button == .left
            ? (.leftMouseDown, .leftMouseUp, .left)
            : (.rightMouseDown, .rightMouseUp, .right)
        for press in 1...type.pressesPerTick {
            guard let down = CGEvent(
                    mouseEventSource: nil, mouseType: downType,
                    mouseCursorPosition: position, mouseButton: mouseButton),
                  let up = CGEvent(
                    mouseEventSource: nil, mouseType: upType,
                    mouseCursorPosition: position, mouseButton: mouseButton) else {
                Log.error("macro: failed to build click events at \(position)")
                return
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(press))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(press))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func postKey(keyCode: Int64, modifiers: UInt64) {
        guard let down = CGEvent(
                keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(
                keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            Log.error("macro: failed to build key events for keyCode \(keyCode)")
            return
        }
        let flags = CGEventFlags(rawValue: modifiers)
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Settings pane

// Bridges the module to SwiftUI so Start/Stop state and captured points refresh.
final class AutoclickPaneModel: ObservableObject {
    weak var module: AutoclickModule?
    @Published var captureCountdown: Int?
    @Published var stepCaptureCountdown: Int?
}

private struct AutoclickSettingsPane: View {
    @ObservedObject var model: AutoclickPaneModel
    let settings: Settings

    private let moduleID = ModuleCatalog.autoclicker.id
    @State private var mode: AutoclickModule.Mode
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
        _mode = State(initialValue: settings.moduleString(id: id, key: AutoclickModule.Key.mode)
            .flatMap(AutoclickModule.Mode.init) ?? .simple)
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
                DSSectionLabel("Mode")
                HStack(spacing: 8) {
                    ForEach(AutoclickModule.Mode.allCases, id: \.rawValue) { value in
                        DSChip(title: value.displayName, selected: mode == value) {
                            mode = value
                            settings.setModuleString(value.rawValue, id: moduleID, key: AutoclickModule.Key.mode)
                        }
                    }
                }
            }

            if mode == .macro {
                MacroEditorSection(model: model, settings: settings,
                                   button: button, clickType: clickType)
            } else {
                simpleControls
            }
        }
    }

    @ViewBuilder private var simpleControls: some View {
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

// MARK: - Macro editor

// Builds the step list: clicks use the Click/Button chips from the module's
// settings at the moment the step is added, key steps record the next chord,
// waits take the entered duration.
private struct MacroEditorSection: View {
    @ObservedObject var model: AutoclickPaneModel
    let settings: Settings
    let button: AutoclickPlan.Button
    let clickType: AutoclickPlan.ClickType

    private let moduleID = ModuleCatalog.autoclicker.id
    @State private var macro: Macro
    @State private var waitSeconds: Double = 0.5
    @State private var recordingKey = false
    @State private var keyCapture = ShortcutCapture()

    init(model: AutoclickPaneModel, settings: Settings,
         button: AutoclickPlan.Button, clickType: AutoclickPlan.ClickType) {
        self.model = model
        self.settings = settings
        self.button = button
        self.clickType = clickType
        _macro = State(initialValue: settings.moduleString(
            id: ModuleCatalog.autoclicker.id, key: AutoclickModule.Key.macro)
            .flatMap(Macro.decode) ?? Macro())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSectionLabel("Steps")
            if macro.steps.isEmpty {
                Text("No steps yet. A macro runs its steps in order, then repeats.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(macro.steps.enumerated()), id: \.offset) { index, step in
                        stepRow(index: index, step: step)
                    }
                }
            }

            DSSectionLabel("Add step")
            HStack(spacing: 8) {
                Button("Click at Cursor") { append(.click(
                    button: button, type: clickType, x: nil, y: nil)) }
                    .buttonStyle(GhostButtonStyle())
                Button(pointButtonTitle) { beginPointCapture() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(model.stepCaptureCountdown != nil)
                Button(recordingKey ? "Press keys\u{2026}" : "Key Press") { recordKey() }
                    .buttonStyle(GhostButtonStyle())
            }
            HStack(spacing: 8) {
                Button("Wait") { append(.wait(seconds: waitSeconds)) }
                    .buttonStyle(GhostButtonStyle())
                DSNumberField(
                    placeholder: "sec", value: $waitSeconds, range: 0.01...600,
                    fractionDigits: 2, onCommit: { waitSeconds = $0 })
                Text("seconds")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }
            Text("Click steps use the Click and Button choices from Autoclick mode at the moment you add them.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dsFaint)
                .fixedSize(horizontal: false, vertical: true)

            DSSectionLabel("Repeat")
            HStack(spacing: 8) {
                Text("Runs")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dsMuted)
                DSNumberField(
                    placeholder: "runs",
                    value: Binding(
                        get: { Double(macro.repeatCount) },
                        set: { macro.repeatCount = Int($0) }),
                    range: 0...1_000_000,
                    fractionDigits: 0,
                    onCommit: { _ in persist() })
                Text("0 = until stopped")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
                Text("Pause")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dsMuted)
                    .padding(.leading, 8)
                DSNumberField(
                    placeholder: "sec",
                    value: Binding(
                        get: { macro.interval },
                        set: { macro.interval = $0 }),
                    range: 0...600,
                    fractionDigits: 2,
                    onCommit: { _ in persist() })
                Text("between runs")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }
        }
        .onDisappear { if recordingKey { keyCapture.end(); recordingKey = false } }
    }

    private func stepRow(index: Int, step: MacroStep) -> some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.dsFaint)
            Text(step.summary)
                .font(.system(size: 12))
                .foregroundStyle(Color.dsPaper)
                .lineLimit(1)
            Spacer()
            Button {
                move(index: index, by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(index == 0 ? Color.dsFaint : Color.dsMuted)
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            Button {
                move(index: index, by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(index == macro.steps.count - 1 ? Color.dsFaint : Color.dsMuted)
            }
            .buttonStyle(.plain)
            .disabled(index == macro.steps.count - 1)
            Button {
                macro.steps.remove(at: index)
                persist()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Color.dsInk2,
            in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous)
                .strokeBorder(Color.dsLine, lineWidth: 1))
    }

    private func append(_ step: MacroStep) {
        macro.steps.append(step)
        persist()
    }

    private func move(index: Int, by offset: Int) {
        let target = index + offset
        guard macro.steps.indices.contains(index), macro.steps.indices.contains(target) else { return }
        macro.steps.swapAt(index, target)
        persist()
    }

    private func persist() {
        settings.setModuleString(
            macro.encodedJSON(), id: moduleID, key: AutoclickModule.Key.macro)
    }

    private var pointButtonTitle: String {
        if let n = model.stepCaptureCountdown { return "Capturing in \(n)\u{2026}" }
        return "Click at Point (3s)"
    }

    private func beginPointCapture() {
        model.stepCaptureCountdown = 3
        tickPointCapture()
    }

    private func tickPointCapture() {
        guard let n = model.stepCaptureCountdown else { return }
        if n == 0 {
            let point = AutoclickModule.currentCursorTopLeft()
            append(.click(
                button: button, type: clickType,
                x: Double(point.x), y: Double(point.y)))
            model.stepCaptureCountdown = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            model.stepCaptureCountdown = n - 1
            tickPointCapture()
        }
    }

    private func recordKey() {
        if recordingKey {
            keyCapture.end()
            recordingKey = false
            return
        }
        recordingKey = true
        keyCapture.begin { preset in
            recordingKey = false
            append(.key(keyCode: preset.keyCode, modifiers: preset.modifiers.rawValue))
        }
    }
}
