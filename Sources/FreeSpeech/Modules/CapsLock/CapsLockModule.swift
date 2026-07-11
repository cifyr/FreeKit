import AppKit
import SwiftUI
import FreeSpeechCore

// Caps Lock remap. Two layers: hidutil remaps Caps Lock -> F18 at the HID level
// (a session event tap cannot observe caps press/release — the toggle happens
// below it, and this also keeps the caps LED off), then the shared event tap
// turns F18 into the chosen behavior via HyperKeyMapper. The hidutil mapping is
// session-scoped: it clears on deactivate/quit and does not survive reboot, so
// activate() reapplies it. If the app crashes while enabled, Caps Lock acts as
// F18 until relaunch or reboot.
final class CapsLockModule: AppModule, EventRewriter {
    let info = ModuleCatalog.capsLock

    private let settings: Settings
    private let hub: EventTapHub
    private let mapper: HyperKeyMapper

    private static let behaviorKey = "behavior"
    // kVK_F18. Assumes no physical F18 key; real ones are vanishingly rare.
    private static let triggerKeyCode: Int64 = 79
    private static let capsLockUsage: UInt64 = 0x7_0000_0039
    private static let f18Usage: UInt64 = 0x7_0000_006D

    init(settings: Settings, hub: EventTapHub) {
        self.settings = settings
        self.hub = hub
        let behavior = settings.moduleString(id: ModuleCatalog.capsLock.id, key: Self.behaviorKey)
            .flatMap(HyperKeyMapper.Behavior.init) ?? .hyper
        mapper = HyperKeyMapper(behavior: behavior)
    }

    func activate() {
        setHidRemapEnabled(true)
        hub.addRewriter(self)
    }

    func deactivate() {
        hub.removeRewriter(self)
        setHidRemapEnabled(false)
    }

    func setMenuBarItemVisible(_ visible: Bool) {}

    // A single chip row: stays inline in the control-center card instead of
    // opening a whole window.
    var settingsStyle: ModuleSettingsStyle { .inline }

    func makeSettingsPane() -> AnyView {
        AnyView(CapsLockSettingsPane(
            current: mapper.behavior,
            onSelect: { [weak self] behavior in
                guard let self else { return }
                self.settings.setModuleString(
                    behavior.rawValue, id: self.info.id, key: Self.behaviorKey)
                self.mapper.reset(behavior: behavior)
                Log.info("capslock: behavior=\(behavior.rawValue)")
            }))
    }

    // MARK: - EventRewriter

    func rewrite(kind: HotkeyRecognizer.EventKind, event: CGEvent) -> EventRewriteVerdict {
        switch kind {
        case .keyDown, .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.triggerKeyCode {
                let now = CFAbsoluteTimeGetCurrent()
                let action = kind == .keyDown
                    ? mapper.handleTriggerDown(at: now)
                    : mapper.handleTriggerUp(at: now)
                if action == .swallowAndEmitEscape {
                    // Posted async: injecting from inside the tap callback would
                    // re-enter this tap with the callback still on the stack.
                    DispatchQueue.main.async { Self.postEscape() }
                }
                return .swallow
            }
            if case .rewriteFlags(let flags) = mapper.handleOtherKey(flags: event.flags.rawValue) {
                event.flags = CGEventFlags(rawValue: flags)
            }
            return .pass
        case .flagsChanged:
            return .pass
        }
    }

    private static func postEscape() {
        let escape: CGKeyCode = 53
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: escape, keyDown: false) else {
            Log.error("capslock: failed to build Escape events")
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - HID remap

    private func setHidRemapEnabled(_ enabled: Bool) {
        // Clearing sets an empty map, which would also drop any hidutil mappings
        // the user made outside this app — acceptable for a personal machine.
        let mapping = enabled
            ? "[{\"HIDKeyboardModifierMappingSrc\":\(Self.capsLockUsage),\"HIDKeyboardModifierMappingDst\":\(Self.f18Usage)}]"
            : "[]"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", "{\"UserKeyMapping\":\(mapping)}"]
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let detail = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
                Log.error("capslock: hidutil exited \(process.terminationStatus): \(detail)")
            } else {
                Log.info("capslock: HID remap \(enabled ? "applied (Caps Lock -> F18)" : "cleared")")
            }
        } catch {
            Log.error("capslock: failed to run hidutil: \(error.localizedDescription)")
        }
    }
}

private struct CapsLockSettingsPane: View {
    @State var current: HyperKeyMapper.Behavior
    let onSelect: (HyperKeyMapper.Behavior) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BEHAVIOR")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(Color.dsMuted)
            HStack(spacing: 8) {
                ForEach(HyperKeyMapper.Behavior.allCases, id: \.rawValue) { behavior in
                    DSChip(title: behavior.displayName, selected: current == behavior) {
                        current = behavior
                        onSelect(behavior)
                    }
                }
            }
            Text("Hyper is Cmd+Opt+Ctrl+Shift — a modifier layer no app uses by default, free for your own shortcuts. Remap is applied while this module is on and removed when it is off or the app quits.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dsFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
