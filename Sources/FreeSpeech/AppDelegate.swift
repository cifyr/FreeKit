import AppKit
import FreeSpeechCore

// Composition root for the suite. Working name "FreeKit" (placeholder — rename
// is a string change here and in ControlCenterWindow). The bundle identifier
// and signing identity stay com.cadenwarren.freespeech / "FreeSpeech Dev" so
// existing TCC grants keep working.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let eventHub = EventTapHub()
    private let permissionCoach = PermissionCoachController()
    private var registry: ModuleRegistry!
    private var speech: SpeechModule!
    private var controlCenter: ControlCenterWindowController!
    private var homeItem: SuiteStatusItem!

    private var accessibilityPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.setLogFile(AppPaths.logFile)
        Log.info("FreeKit suite launching (pid \(ProcessInfo.processInfo.processIdentifier))")

        registry = ModuleRegistry(settings: settings)
        speech = SpeechModule(
            settings: settings, hub: eventHub, permissionCoach: permissionCoach,
            ensureEventTap: { [weak self] in self?.startEventTap(promptForAccessibility: true) })
        registry.register(speech)
        registry.register(NotebookModule(settings: settings, hub: eventHub))
        registry.register(AutoclickModule(
            settings: settings, hub: eventHub, permissionCoach: permissionCoach))
        registry.register(StatsModule(settings: settings))
        registry.register(CapsLockModule(settings: settings, hub: eventHub))
        for info in [ModuleCatalog.menuBarManager, ModuleCatalog.cotypist,
                     ModuleCatalog.appCleaner, ModuleCatalog.linearMouse,
                     ModuleCatalog.clop, ModuleCatalog.boringNotch] {
            registry.register(PlaceholderModule(info: info))
        }

        controlCenter = ControlCenterWindowController(registry: registry)
        homeItem = SuiteStatusItem(onOpenControlCenter: { [weak self] in
            self?.controlCenter.show()
        })

        registry.activateEnabledModules()
        installEventTapOrPollForAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Deactivation matters beyond hygiene: the Caps Lock module must undo
        // its hidutil remap or Caps Lock stays dead after quit.
        for module in registry.modules
        where module.info.status == .available && settings.moduleEnabled(id: module.info.id) {
            module.deactivate()
        }
        eventHub.stop()
        Log.info("FreeKit terminating")
    }

    // MARK: - Shared event tap lifecycle

    private func installEventTapOrPollForAccessibility() {
        // During onboarding the setup window owns the permission UX, so stay quiet here.
        let onboarded = settings.hasCompletedOnboarding
        if Permissions.accessibilityTrusted(promptIfNeeded: onboarded) {
            startEventTap(promptForAccessibility: false)
            return
        }
        if onboarded {
            speechIfEnabled?.noteAccessibilityMissing()
            permissionCoach.show(.accessibility)
        }
        beginAccessibilityPoll()
    }

    // Poll until granted: AX trust can change at any time and there is no notification API.
    private func beginAccessibilityPoll() {
        guard accessibilityPollTimer == nil else { return }
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, Permissions.accessibilityTrusted(promptIfNeeded: false) else { return }
            self.accessibilityPollTimer?.invalidate()
            self.accessibilityPollTimer = nil
            Log.info("accessibility granted, starting event tap")
            self.startEventTap(promptForAccessibility: false)
        }
    }

    private func startEventTap(promptForAccessibility: Bool) {
        guard !eventHub.isRunning else { return }
        if promptForAccessibility, !Permissions.accessibilityTrusted(promptIfNeeded: true) {
            beginAccessibilityPoll()
            return
        }
        do {
            try eventHub.start()
            speechIfEnabled?.noteAccessibilityGranted()
        } catch {
            Log.error("event tap start failed: \(error.localizedDescription)")
            speechIfEnabled?.noteAccessibilityMissing()
            beginAccessibilityPoll()
        }
    }

    // Accessibility errors surface through Speech's HUD/status item, but only
    // when that module is actually on.
    private var speechIfEnabled: SpeechModule? {
        settings.moduleEnabled(id: ModuleCatalog.speech.id) ? speech : nil
    }
}
