import AppKit
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import SwiftUI
import FreeKitCore

// Amphetamine: keep the Mac awake on demand. Session policy (durations,
// vectors, countdown text) lives in Core's AmphetaminePlan; this layer holds
// the actual IOPMAssertions. The assertions belong to this module object, not
// to any window, so a session survives every FreeKit window closing — it ends
// only on timer expiry, an explicit stop, or the app quitting.
//
// Lid-closed keep-awake: an IOPMAssertion only vetoes *idle* sleep, so closing
// the lid still forces sleep no matter what is asserted. The lever that stops
// it — with no external display, no admin password, and no `pmset` — is the
// IOPMrootDomain user client's `kPMSetClamshellSleepState` selector (value 12,
// public in IOKit's IOPMLibDefs.h). It flips a rootDomain bit that makes the
// kernel not sleep on lid close; the same call Amphetamine uses. We hold it
// alongside the display-idle assertion (see AmphetaminePlan.vectors): that
// assertion, not the clamshell bit, is what keeps a video decoding and stops
// loginwindow from locking the screen behind the closed lid. We deliberately
// never touch `displaysleep` — forcing a display-sleep transition is what makes
// the screen lock on lid close.
//
// The clamshell bit lives on the rootDomain singleton, not on our connection,
// so it does NOT self-clear when the process dies (only selector-12-with-0 or a
// reboot clears it). `clamshellOverridePending` is persisted so a crash leaves a
// trail activate() finds and clears on next launch. It can also lapse across
// AC<->battery transitions on Apple Silicon, so a power-source watcher re-asserts
// it. It costs no battery-drain risk beyond keeping the Mac awake, but lid-closed
// in a bag can still overheat, so AmphetaminePlan's floor ends the session at 20%
// off AC.
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

    // Set only while this session holds the clamshell-sleep bit down; drives
    // endSession's cleanup and the crash-recovery check in activate().
    private var clamshellOverrideActive = false
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var lastBatteryCheck = Date.distantPast

    // IOPMrootDomain user-client selector that toggles clamshell (lid-close)
    // sleep; 1 disables lid-close sleep, 0 restores it. Public in IOPMLibDefs.h,
    // needs no root — proven on this hardware.
    private static let kPMSetClamshellSleepState: UInt32 = 12

    // Raw assertion-type strings, not the kIOPMAssertionType* macros: C
    // #defines of CFSTR don't import into Swift.
    private static let preventIdleSystemSleep = "PreventUserIdleSystemSleep"
    private static let preventIdleDisplaySleep = "PreventUserIdleDisplaySleep"

    enum Key {
        static let keepDisplayAwake = "keepDisplayAwake"
        static let keepAwakeWithLidClosed = "keepAwakeWithLidClosed"
        // Persisted the instant we disable clamshell sleep, cleared the instant
        // we restore it — so a crash mid-session leaves a trail activate() can
        // find and clean up, instead of a Mac stuck never sleeping on lid close.
        static let clamshellOverridePending = "clamshellOverridePending"
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

    var keepAwakeWithLidClosed: Bool {
        get { settings.moduleBool(id: info.id, key: Key.keepAwakeWithLidClosed) ?? false }
        set {
            settings.setModuleBool(newValue, id: info.id, key: Key.keepAwakeWithLidClosed)
            // Apply to any running session immediately: flipping this on/off used
            // to only matter for the *next* session, which is easy to forget —
            // the toggle looked dead. Now it engages or releases clamshell live.
            applyLidClosedToActiveSession(newValue)
        }
    }

    private func applyLidClosedToActiveSession(_ enabled: Bool) {
        guard let current = activePlan else { return }
        if enabled, !clamshellOverrideActive {
            guard enableClamshellOverride() else {
                Log.error("amphetamine: could not engage lid-closed on the running session")
                return
            }
        } else if !enabled, clamshellOverrideActive {
            disableClamshellOverride()
        }
        let plan = AmphetaminePlan(
            duration: current.duration,
            keepDisplayAwake: keepDisplayAwake,
            keepAwakeWithLidClosed: enabled)
        // Lid-closed forces the display assertion on (it's what stops the lock);
        // pick it up now if the running session didn't already hold it.
        if plan.vectors().displayIdleSleep, !hasDisplayAssertion {
            hasDisplayAssertion = createAssertion(
                type: Self.preventIdleDisplaySleep,
                reason: "FreeKit Amphetamine session (\(current.duration.displayName))",
                into: &displayAssertion)
        }
        activePlan = plan
        updateStatusIcon()
        paneModel.objectWillChange.send()
    }

    private var clamshellOverridePending: Bool {
        get { settings.moduleBool(id: info.id, key: Key.clamshellOverridePending) ?? false }
        set { settings.setModuleBool(newValue, id: info.id, key: Key.clamshellOverridePending) }
    }

    var isSessionActive: Bool { activePlan != nil }

    var sessionElapsed: TimeInterval {
        sessionStart.map { Date().timeIntervalSince($0) } ?? 0
    }

    var sessionRemaining: TimeInterval? {
        activePlan?.remaining(elapsed: sessionElapsed)
    }

    func activate() {
        // If FreeKit crashed or was force-quit mid-session with clamshell sleep
        // disabled, the rootDomain bit stays set with nothing to clear it — the
        // Mac would never sleep on lid close until reboot. Clear it every launch
        // rather than only at endSession. No prompt: selector 12 needs no root.
        guard clamshellOverridePending, !clamshellOverrideActive else { return }
        Log.error("amphetamine: found a pending clamshell disable from a previous run, clearing it")
        if setClamshellSleepDisabled(false) {
            clamshellOverridePending = false
        } else {
            Log.error("amphetamine: failed to clear stale clamshell disable — a reboot will clear it")
        }
    }

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
            keepAwakeWithLidClosed: keepAwakeWithLidClosed)
        let vectors = plan.vectors()
        let reason = "FreeKit Amphetamine session (\(duration.displayName))"

        if vectors.clamshellSleep {
            guard enableClamshellOverride() else {
                Log.error("amphetamine: session not started, clamshell override failed or was declined")
                return
            }
        }
        guard createAssertion(
            type: Self.preventIdleSystemSleep, reason: reason, into: &systemAssertion) else {
            Log.error("amphetamine: session not started, system assertion failed")
            if vectors.clamshellSleep { disableClamshellOverride() }
            return
        }
        hasSystemAssertion = true
        if vectors.displayIdleSleep {
            hasDisplayAssertion = createAssertion(
                type: Self.preventIdleDisplaySleep, reason: reason, into: &displayAssertion)
        }
        activePlan = plan
        sessionStart = Date()
        Log.info("amphetamine: session started duration=\(duration.displayName) " +
                  "display=\(vectors.displayIdleSleep) lidClosed=\(vectors.clamshellSleep)")
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
        guard isSessionActive || hasSystemAssertion || hasDisplayAssertion || clamshellOverrideActive
        else { return }
        if hasSystemAssertion {
            IOPMAssertionRelease(systemAssertion)
            hasSystemAssertion = false
        }
        if hasDisplayAssertion {
            IOPMAssertionRelease(displayAssertion)
            hasDisplayAssertion = false
        }
        if clamshellOverrideActive {
            disableClamshellOverride()
        }
        tickTimer?.invalidate()
        tickTimer = nil
        activePlan = nil
        sessionStart = nil
        Log.info("amphetamine: session ended (\(reason))")
        updateStatusIcon()
        paneModel.objectWillChange.send()
    }

    // MARK: - Clamshell override (kPMSetClamshellSleepState)

    // True once a session disabled clamshell sleep but a crash/force-quit left it
    // stuck — the settings pane offers an immediate retry instead of making the
    // user wait for the next launch's activate() check.
    var hasStaleClamshellOverride: Bool { clamshellOverridePending && !clamshellOverrideActive }

    func retryClamshellCleanup() {
        if setClamshellSleepDisabled(false) {
            clamshellOverridePending = false
            paneModel.objectWillChange.send()
        } else {
            Log.error("amphetamine: retry clamshell cleanup failed — a reboot will clear it")
        }
    }

    private func enableClamshellOverride() -> Bool {
        guard setClamshellSleepDisabled(true) else { return false }
        clamshellOverridePending = true
        clamshellOverrideActive = true
        startPowerSourceMonitor()
        Log.info("amphetamine: clamshell sleep disabled — Mac stays awake with the lid closed")
        return true
    }

    private func disableClamshellOverride() {
        stopPowerSourceMonitor()
        if setClamshellSleepDisabled(false) {
            clamshellOverridePending = false
        } else {
            Log.error("amphetamine: failed to restore clamshell sleep; the settings pane offers a " +
                      "retry, or a reboot clears it")
        }
        clamshellOverrideActive = false
    }

    // One IOPMrootDomain user-client call. The connection can close immediately:
    // the bit it sets lives on the rootDomain singleton, not on the connection.
    private func setClamshellSleepDisabled(_ disabled: Bool) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            Log.error("amphetamine: IOPMrootDomain not found")
            return false
        }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == kIOReturnSuccess else {
            Log.error("amphetamine: IOServiceOpen(IOPMrootDomain) failed: IOReturn \(opened)")
            return false
        }
        defer { IOServiceClose(connection) }
        var input: UInt64 = disabled ? 1 : 0
        let result = IOConnectCallScalarMethod(
            connection, Self.kPMSetClamshellSleepState, &input, 1, nil, nil)
        guard result == kIOReturnSuccess else {
            Log.error("amphetamine: kPMSetClamshellSleepState(\(input)) failed: IOReturn \(result)")
            return false
        }
        return true
    }

    // The clamshell bit can lapse when the power source flips on Apple Silicon,
    // so re-assert it on every AC<->battery change for the life of the session.
    private func startPowerSourceMonitor() {
        guard powerSourceRunLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let rawContext else { return }
            Unmanaged<AmphetamineModule>.fromOpaque(rawContext)
                .takeUnretainedValue().reassertClamshellIfNeeded()
        }, context)?.takeRetainedValue() else {
            Log.error("amphetamine: could not create power-source notification source")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceRunLoopSource = source
    }

    private func stopPowerSourceMonitor() {
        guard let source = powerSourceRunLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceRunLoopSource = nil
    }

    private func reassertClamshellIfNeeded() {
        guard clamshellOverrideActive else { return }
        if setClamshellSleepDisabled(true) {
            Log.info("amphetamine: re-asserted clamshell sleep disable after a power-source change")
        } else {
            Log.error("amphetamine: failed to re-assert clamshell sleep disable after power change")
        }
    }

    private static func readBatteryState() -> (percent: Int?, onACPower: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (nil, true) }
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            let current = info[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let capacity = info[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let percent = capacity > 0 ? Int((Double(current) / Double(capacity) * 100).rounded()) : 0
            let onAC = (info[kIOPSPowerSourceStateKey as String] as? String) == (kIOPSACPowerValue as String)
            return (percent, onAC)
        }
        return (nil, true)
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
        // Only the lid-closed path needs the battery floor — the other two
        // vectors just veto idle sleep, so the Mac still sleeps normally on low
        // battery even off AC. Checked every 5s, not every tick, to avoid
        // hammering IOPSCopyPowerSourcesInfo.
        if plan.vectors().clamshellSleep, Date().timeIntervalSince(lastBatteryCheck) >= 5 {
            lastBatteryCheck = Date()
            let (percent, onACPower) = Self.readBatteryState()
            if let percent, plan.shouldEndForBattery(percent: percent, onACPower: onACPower) {
                Log.error("amphetamine: ending clamshell-override session, battery at \(percent)% off AC")
                endSession(reason: "battery floor reached")
                return
            }
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
        // Checkable and live: toggling here engages/releases clamshell on the
        // running session too, so it works whether flipped before or during.
        let lidItem = NSMenuItem(
            title: "Keep Awake With Lid Closed",
            action: #selector(menuToggleLidClosed), keyEquivalent: "")
        lidItem.target = self
        lidItem.state = keepAwakeWithLidClosed ? .on : .off
        menu.addItem(lidItem)
        let hint = NSMenuItem(
            title: "Right-click toggles Stay Awake", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
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

    @objc private func menuToggleLidClosed() {
        keepAwakeWithLidClosed.toggle()
    }

    @objc private func menuOpenSettings() {
        openSettings()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(
            systemSymbolName: info.symbolName,
            accessibilityDescription: isSessionActive ? "Amphetamine awake" : "Amphetamine idle")
        image?.isTemplate = true
        button.image = image
        // nil at rest inherits the system's default template color — the
        // same one every other menu-bar icon in the suite uses, since none
        // of them override contentTintColor either. A fixed gray tint here
        // was the one icon in the menu bar that didn't match its neighbors.
        // Accent only while a session actually holds the Mac awake, the
        // suite's one "this is live" signal.
        button.contentTintColor = isSessionActive ? DS.accent : nil
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
                DSToggleRow(
                    title: "Keep awake with the lid closed",
                    caption: "Keeps running with the lid shut and no external display — no password needed. The screen won't lock and video keeps playing. Off AC it can warm up in a bag, so the session auto-ends at 20% battery.",
                    isOn: Binding(
                        get: { model.module?.keepAwakeWithLidClosed ?? false },
                        set: { model.module?.keepAwakeWithLidClosed = $0 }))
                Text("Applies to sessions started after the change.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }

            if model.module?.hasStaleClamshellOverride == true {
                DSSettingsCard(title: "Needs attention") {
                    Text("A previous session's lid-close setting didn't clear (likely a crash or force-quit). The Mac may still skip sleep when the lid closes until you clear it or reboot.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsAccent)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry Clearing It") { model.module?.retryClamshellCleanup() }
                        .buttonStyle(GhostButtonStyle())
                }
            }

            DSSettingsCard(title: "Limits") {
                Text("Closing the lid with no external display normally forces sleep — no app-level assertion can veto it. \u{201C}Keep awake with the lid closed\u{201D} above disables just clamshell sleep through a public IOKit call (no password, no other sleep affected), at the battery/heat cost noted there. Sessions survive FreeKit's windows closing, but not quitting FreeKit.")
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
