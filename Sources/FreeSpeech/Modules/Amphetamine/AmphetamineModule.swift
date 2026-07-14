import AppKit
import IOKit.pwr_mgt
import SwiftUI
import FreeSpeechCore

// Amphetamine: keep the Mac awake on demand. Session policy (durations,
// vectors, countdown text) lives in Core's AmphetaminePlan; this layer holds
// the actual IOPMAssertions. The assertions belong to this module object, not
// to any window, so a session survives every FreeKit window closing — it ends
// only on timer expiry, an explicit stop, or the app quitting.
//
// Known limitation, by macOS design: closing the lid with no external display
// forces sleep regardless of any user-space assertion. Preventing that needs
// the root-only SleepDisabled system setting, which v1 deliberately does not
// request. (Possible v2: a pmset-based opt-in if it ever proves worth sudo.)
final class AmphetamineModule: NSObject, AppModule {
    let info = ModuleCatalog.amphetamine

    private let settings: Settings
    private var statusItem: NSStatusItem?
    private let paneModel = AmphetaminePaneModel()

    private(set) var activePlan: AmphetaminePlan?
    private var sessionStart: Date?
    private var systemAssertion = IOPMAssertionID(0)
    private var displayAssertion = IOPMAssertionID(0)
    private var hasSystemAssertion = false
    private var hasDisplayAssertion = false
    private var tickTimer: Timer?

    // Raw assertion-type strings, not the kIOPMAssertionType* macros: C
    // #defines of CFSTR don't import into Swift.
    private static let preventIdleSystemSleep = "PreventUserIdleSystemSleep"
    private static let preventIdleDisplaySleep = "PreventUserIdleDisplaySleep"

    enum Key {
        static let keepDisplayAwake = "keepDisplayAwake"
    }

    init(settings: Settings) {
        self.settings = settings
        super.init()
        paneModel.module = self
    }

    var keepDisplayAwake: Bool {
        get { settings.moduleBool(id: info.id, key: Key.keepDisplayAwake) ?? true }
        set { settings.setModuleBool(newValue, id: info.id, key: Key.keepDisplayAwake) }
    }

    var isSessionActive: Bool { activePlan != nil }

    var sessionElapsed: TimeInterval {
        sessionStart.map { Date().timeIntervalSince($0) } ?? 0
    }

    var sessionRemaining: TimeInterval? {
        activePlan?.remaining(elapsed: sessionElapsed)
    }

    func activate() {}

    func deactivate() {
        endSession(reason: "module disabled")
        statusItem?.isVisible = false
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    button.target = self
                    button.action = #selector(statusItemClicked)
                    // Right-click is the quick Stay Awake toggle; left-click
                    // opens the tier menu — so the click must reach us instead
                    // of a statically attached NSMenu.
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                }
                statusItem = item
                updateStatusIcon()
            }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    var settingsPopupSize: NSSize { NSSize(width: 600, height: 620) }

    func makeSettingsPane() -> AnyView {
        paneModel.module = self
        return AnyView(AmphetamineSettingsPane(model: paneModel))
    }

    // MARK: - Session lifecycle

    func startSession(duration: AmphetaminePlan.Duration) {
        endSession(reason: "replaced by new session")
        let plan = AmphetaminePlan(
            duration: duration,
            keepDisplayAwake: keepDisplayAwake,
            keepAwakeWithLidClosed: false)
        let vectors = plan.vectors()
        let reason = "FreeKit Amphetamine session (\(duration.displayName))"
        guard createAssertion(
            type: Self.preventIdleSystemSleep, reason: reason, into: &systemAssertion) else {
            Log.error("amphetamine: session not started, system assertion failed")
            return
        }
        hasSystemAssertion = true
        if vectors.displayIdleSleep {
            hasDisplayAssertion = createAssertion(
                type: Self.preventIdleDisplaySleep, reason: reason, into: &displayAssertion)
        }
        activePlan = plan
        sessionStart = Date()
        Log.info("amphetamine: session started duration=\(duration.displayName) display=\(vectors.displayIdleSleep)")
        // Ticking drives both the menu-bar countdown and timer expiry;
        // indefinite sessions still tick so the settings pane's elapsed
        // readout stays live.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        updateStatusIcon()
        paneModel.objectWillChange.send()
    }

    func endSession(reason: String) {
        guard isSessionActive || hasSystemAssertion || hasDisplayAssertion else { return }
        if hasSystemAssertion {
            IOPMAssertionRelease(systemAssertion)
            hasSystemAssertion = false
        }
        if hasDisplayAssertion {
            IOPMAssertionRelease(displayAssertion)
            hasDisplayAssertion = false
        }
        tickTimer?.invalidate()
        tickTimer = nil
        activePlan = nil
        sessionStart = nil
        Log.info("amphetamine: session ended (\(reason))")
        updateStatusIcon()
        paneModel.objectWillChange.send()
    }

    func toggleStayAwake() {
        if isSessionActive {
            endSession(reason: "stay-awake toggled off")
        } else {
            startSession(duration: .indefinite)
        }
    }

    private func tick() {
        guard let plan = activePlan else { return }
        if plan.isExpired(elapsed: sessionElapsed) {
            endSession(reason: "timer elapsed")
            return
        }
        updateStatusIcon()
        paneModel.objectWillChange.send()
    }

    private func createAssertion(type: String, reason: String,
                                 into id: inout IOPMAssertionID) -> Bool {
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString, &id)
        guard result == kIOReturnSuccess else {
            Log.error("amphetamine: IOPMAssertionCreateWithName(\(type)) failed: IOReturn \(result)")
            return false
        }
        return true
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            toggleStayAwake()
        } else {
            showMenu()
        }
    }

    // Attach the menu only for the duration of this click: a permanently
    // attached menu would swallow the right-click toggle.
    private func showMenu() {
        guard let statusItem else { return }
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let statusTitle: String
        if let plan = activePlan {
            statusTitle = plan.duration.seconds == nil
                ? "Awake until you stop it"
                : "Awake — \(AmphetaminePlan.countdownText(remaining: sessionRemaining)) left"
        } else {
            statusTitle = "Sleeping normally"
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        for duration in AmphetaminePlan.Duration.presets {
            let title = duration.seconds == nil
                ? "Stay Awake Until Stopped"
                : "Keep awake \(duration.displayName)"
            let item = NSMenuItem(
                title: title,
                action: #selector(menuStartSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = durationToken(duration)
            menu.addItem(item)
        }
        if isSessionActive {
            menu.addItem(.separator())
            let stop = NSMenuItem(
                title: "End Session", action: #selector(menuEndSession), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(
            title: "Right-click toggles Stay Awake", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let lidNote = NSMenuItem(
            title: "Lid-close sleep can't be prevented", action: nil, keyEquivalent: "")
        lidNote.isEnabled = false
        menu.addItem(lidNote)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Amphetamine Settings\u{2026}", action: #selector(menuOpenSettings),
            keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        return menu
    }

    // Durations round-trip through the menu as "minutes count or 0 for
    // indefinite" so representedObject stays a plain NSNumber.
    private func durationToken(_ duration: AmphetaminePlan.Duration) -> NSNumber {
        switch duration {
        case .minutes(let m): return NSNumber(value: m)
        case .indefinite: return NSNumber(value: 0)
        }
    }

    private func duration(fromToken token: NSNumber) -> AmphetaminePlan.Duration {
        token.intValue > 0 ? .minutes(token.intValue) : .indefinite
    }

    @objc private func menuStartSession(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? NSNumber else { return }
        startSession(duration: duration(fromToken: token))
    }

    @objc private func menuEndSession() {
        endSession(reason: "menu stop")
    }

    @objc private func menuOpenSettings() {
        openSettings()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(
            systemSymbolName: info.symbolName,
            accessibilityDescription: isSessionActive ? "Amphetamine awake" : "Amphetamine idle")
        // Without isTemplate, contentTintColor is ignored and the glyph draws in its raw
        // (near-black) fill — invisible against the menu bar's dark background.
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = isSessionActive ? DS.muted : nil
        let title: String
        if let plan = activePlan {
            title = " " + AmphetaminePlan.countdownText(
                remaining: plan.duration.seconds == nil ? nil : sessionRemaining)
        } else {
            title = ""
        }
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
        button.toolTip = isSessionActive
            ? "Amphetamine: keeping the Mac awake (right-click to stop)"
            : "Amphetamine: right-click to stay awake, click for timers"
    }
}

// MARK: - Settings pane

final class AmphetaminePaneModel: ObservableObject {
    weak var module: AmphetamineModule?
}

private struct AmphetamineSettingsPane: View {
    @ObservedObject var model: AmphetaminePaneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSettingsCard(title: "Current session") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(model.module?.isSessionActive == true
                                             ? Color.dsAccent : Color.dsPaper)
                            .dsContentCrossfade(statusTitle)
                        Text(statusDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsFaint)
                            .dsContentCrossfade(statusDetail)
                    }
                    Spacer()
                    if model.module?.isSessionActive == true {
                        Button("End Session") { model.module?.endSession(reason: "settings stop") }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
            }

            DSSettingsCard(title: "Keep awake") {
                HStack(spacing: 8) {
                    ForEach(Array(AmphetaminePlan.Duration.presets.enumerated()), id: \.offset) { _, duration in
                        DSChip(title: duration.displayName, selected: false) {
                            model.module?.startSession(duration: duration)
                        }
                        .fixedSize()
                    }
                }
                Text("Timers end the session on their own; \u{201C}Until I stop\u{201D} holds until you end it here or right-click the menu bar icon.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DSSettingsCard(title: "Options") {
                DSToggleRow(
                    title: "Keep the display awake too",
                    caption: "Off keeps only the system awake: the screen may still dim and sleep.",
                    isOn: Binding(
                        get: { model.module?.keepDisplayAwake ?? true },
                        set: { model.module?.keepDisplayAwake = $0 }))
                Text("Applies to sessions started after the change.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }

            DSSettingsCard(title: "Limits") {
                Text("Closing the lid with no external display attached always sleeps the Mac: macOS treats it as a forced sleep no app-level assertion can veto. Sessions survive FreeKit's windows closing, but not quitting FreeKit.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusTitle: String {
        guard let module = model.module, module.isSessionActive else { return "Sleeping normally" }
        guard let remaining = module.sessionRemaining else { return "Awake until you stop it" }
        return "Awake — \(AmphetaminePlan.countdownText(remaining: remaining)) left"
    }

    private var statusDetail: String {
        guard let module = model.module, module.isSessionActive else {
            return "Pick a timer or right-click the menu bar icon to stay awake."
        }
        return module.keepDisplayAwake
            ? "System and display sleep are both held off."
            : "System sleep is held off; the display may still sleep."
    }
}
