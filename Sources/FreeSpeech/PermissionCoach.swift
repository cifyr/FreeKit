import AppKit
import SwiftUI
import FreeSpeechCore

// Guided permission granting: opens System Settings on the right pane, then
// floats a small instruction panel next to the Settings window telling the
// user exactly what to flip. Polls the permission and dismisses itself with a
// confirmation the moment macOS reports it granted.
enum CoachPermission {
    case microphone
    case accessibility
    case screenRecording

    var title: String {
        switch self {
        case .microphone: return "Allow microphone access"
        case .accessibility: return "Turn on Accessibility"
        case .screenRecording: return "Turn on Screen Recording"
        }
    }

    var instruction: String {
        switch self {
        case .microphone:
            return "Flip the switch next to FreeKit in the Microphone list."
        case .accessibility:
            return "Flip the switch next to FreeKit in the list. Not listed? Click + at the bottom and pick FreeKit from Applications."
        case .screenRecording:
            return "Flip the switch next to FreeKit in the list. macOS may ask to quit and reopen the app."
        }
    }

    var isGranted: () -> Bool {
        switch self {
        case .microphone:
            return { Permissions.microphoneAuthorized() }
        case .accessibility:
            return { Permissions.accessibilityTrusted(promptIfNeeded: false) }
        case .screenRecording:
            return { Permissions.screenRecordingAuthorized(requestIfNeeded: false) }
        }
    }

    func openSettingsPane() {
        switch self {
        case .microphone: Permissions.openMicrophoneSettings()
        case .accessibility: Permissions.openAccessibilitySettings()
        case .screenRecording: Permissions.openScreenRecordingSettings()
        }
    }
}

final class PermissionCoachController {
    fileprivate final class CoachState: ObservableObject {
        @Published var granted = false
        let permission: CoachPermission
        init(permission: CoachPermission) { self.permission = permission }
    }

    private static let panelSize = CGSize(width: 340, height: 96)
    private static let settingsBundleID = "com.apple.systempreferences"

    private var panel: NSPanel?
    private var pollTimer: Timer?
    private var state: CoachState?
    private var sawSettingsWindow = false

    func show(_ permission: CoachPermission) {
        dismiss()
        Log.info("permission coach: opening System Settings for \(permission)")
        permission.openSettingsPane()

        let state = CoachState(permission: permission)
        self.state = state
        sawSettingsWindow = false

        let hosting = NSHostingView(rootView: PermissionCoachView(
            state: state, onDismiss: { [weak self] in self?.dismiss() }))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameOrigin(fallbackOrigin())
        self.panel = panel

        // System Settings takes a moment to launch; the first ticks find and
        // track its window, later ones watch for the grant.
        reposition()
        panel.dsFadeIn(duration: DS.durBase)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func dismiss() {
        pollTimer?.invalidate()
        pollTimer = nil
        panel?.orderOut(nil)
        panel = nil
        state = nil
    }

    private func tick() {
        guard let state else { return }
        if state.permission.isGranted() {
            Log.info("permission coach: \(state.permission) granted")
            state.granted = true
            pollTimer?.invalidate()
            pollTimer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.fadeOutAndDismiss()
            }
            return
        }
        // The user closing System Settings without granting means they bailed.
        let settingsRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.settingsBundleID).isEmpty
        if sawSettingsWindow && !settingsRunning {
            Log.info("permission coach: System Settings closed, dismissing")
            dismiss()
            return
        }
        reposition()
    }

    private func fadeOutAndDismiss() {
        guard let panel else { return }
        DSMotionAppKit.run(duration: DS.durBase, { _ in
            panel.animator().alphaValue = 0
        }, completion: { [weak self] in
            self?.dismiss()
        })
    }

    private func reposition() {
        guard let panel else { return }
        guard let target = settingsWindowFrame() else {
            if !sawSettingsWindow { panel.setFrameOrigin(fallbackOrigin()) }
            return
        }
        sawSettingsWindow = true
        let screen = NSScreen.screens.first {
            $0.frame.contains(CGPoint(x: target.midX, y: target.midY))
        } ?? NSScreen.main
        guard let screen else { return }
        let position = CoachPlacement.position(
            panelSize: Self.panelSize, targetFrame: target,
            screenFrame: screen.visibleFrame)
        panel.setFrameOrigin(position.origin)
    }

    // The System Settings window frame via the window list: bounds and owner
    // metadata are readable without any permission (unlike window contents).
    private func settingsWindowFrame() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        // Primary-screen height converts CG top-left coords to AppKit bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        for info in list {
            guard info[kCGWindowOwnerName as String] as? String == "System Settings",
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: boundsDict),
                  cg.width > 200, cg.height > 200 else { continue }
            return CGRect(
                x: cg.minX, y: primaryHeight - cg.maxY,
                width: cg.width, height: cg.height)
        }
        return nil
    }

    private func fallbackOrigin() -> CGPoint {
        let screen = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CoachPlacement.fallbackOrigin(panelSize: Self.panelSize, screenFrame: screen)
    }
}

private struct PermissionCoachView: View {
    @ObservedObject fileprivate var state: PermissionCoachController.CoachState
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if state.granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.dsPaper)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Granted").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dsPaper)
                    Text("All set — switch back to what you were doing.")
                        .font(.system(size: 11)).foregroundStyle(Color.dsMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.permission.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dsPaper)
                    Text(state.permission.instruction)
                        .font(.system(size: 11)).foregroundStyle(Color.dsMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.dsFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 340, height: 96, alignment: .top)
        .background(Color(nsColor: DS.glass),
                    in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
            .strokeBorder(Color.dsLine, lineWidth: 1))
        .animation(DS.animCrossfade, value: state.granted)
    }
}
