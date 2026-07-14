import AppKit
import SwiftUI
import FreeSpeechCore

// HyperKey: the Caps Lock key remap. Two layers: hidutil remaps Caps Lock -> F18 at the HID level
// (a session event tap cannot observe caps press/release — the toggle happens
// below it, and this also keeps the caps LED off), then the shared event tap
// turns F18 into the configured behavior via HyperKeyMapper. The hidutil
// mapping is session-scoped: it clears on deactivate/quit and does not survive
// reboot, so activate() reapplies it. If the app crashes while enabled, Caps
// Lock acts as F18 until relaunch or reboot.
final class HyperKeyModule: AppModule, EventRewriter {
    let info = ModuleCatalog.hyperKey

    private let settings: Settings
    private let hub: EventTapHub
    private let mapper: HyperKeyMapper

    private enum Key {
        static let holdFlags = "holdFlags"
        static let tapEscape = "tapEscape"
        static let legacyBehavior = "behavior"
    }
    // kVK_F18. Assumes no physical F18 key; real ones are vanishingly rare.
    private static let triggerKeyCode: Int64 = 79
    private static let capsLockUsage: UInt64 = 0x7_0000_0039
    private static let f18Usage: UInt64 = 0x7_0000_006D

    init(settings: Settings, hub: EventTapHub) {
        self.settings = settings
        self.hub = hub
        mapper = HyperKeyMapper(config: Self.loadConfig(settings: settings))
    }

    // Reads the composable config, migrating the first release's single
    // "behavior" string if that is all that exists.
    private static func loadConfig(settings: Settings) -> HyperKeyMapper.Config {
        let id = ModuleCatalog.hyperKey.id
        if let flags = settings.moduleInt(id: id, key: Key.holdFlags) {
            return HyperKeyMapper.Config(
                holdFlags: UInt64(flags),
                tapEmitsEscape: settings.moduleBool(id: id, key: Key.tapEscape) ?? false)
        }
        switch settings.moduleString(id: id, key: Key.legacyBehavior) {
        case "command":
            return .command
        case "escapeTapHyperHold":
            return HyperKeyMapper.Config(
                holdFlags: HyperKeyMapper.hyperFlags, tapEmitsEscape: true)
        default:
            return .hyper
        }
    }

    private func saveConfig(_ config: HyperKeyMapper.Config) {
        settings.setModuleInt(Int(config.holdFlags), id: info.id, key: Key.holdFlags)
        settings.setModuleBool(config.tapEmitsEscape, id: info.id, key: Key.tapEscape)
        mapper.reset(config: config)
        Log.info("hyperkey: holdFlags=\(HotkeyModifiers(rawValue: config.holdFlags).symbols.isEmpty ? "none" : HotkeyModifiers(rawValue: config.holdFlags).symbols) tapEscape=\(config.tapEmitsEscape)")
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

    var settingsStyle: ModuleSettingsStyle { .popup }

    func makeSettingsPane() -> AnyView {
        AnyView(HyperKeySettingsPane(
            initial: mapper.config,
            onChange: { [weak self] config in self?.saveConfig(config) }))
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
            Log.error("hyperkey: failed to build Escape events")
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
        // Set both the global property AND the keyboard services directly:
        // on recent macOS the global set alone does not reach the built-in
        // keyboard's HID service, which left Caps Lock unmapped in practice.
        runHidutil(["property", "--set", "{\"UserKeyMapping\":\(mapping)}"],
                   enabled: enabled, scope: "global")
        runHidutil(["property",
                    "--matching", "{\"DeviceUsagePage\":1,\"DeviceUsage\":6}",
                    "--set", "{\"UserKeyMapping\":\(mapping)}"],
                   enabled: enabled, scope: "keyboards")
    }

    private func runHidutil(_ arguments: [String], enabled: Bool, scope: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
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
                Log.error("hyperkey: hidutil (\(scope)) exited \(process.terminationStatus): \(detail)")
            } else {
                Log.info("hyperkey: HID remap \(enabled ? "applied (Caps Lock -> F18)" : "cleared") [\(scope)]")
            }
        } catch {
            Log.error("hyperkey: failed to run hidutil: \(error.localizedDescription)")
        }
    }
}

// Compose any modifier mix for the hold behavior; presets are shortcuts that
// set the same checkboxes.
private struct HyperKeySettingsPane: View {
    @State private var holdFlags: UInt64
    @State private var tapEscape: Bool
    let onChange: (HyperKeyMapper.Config) -> Void

    init(initial: HyperKeyMapper.Config, onChange: @escaping (HyperKeyMapper.Config) -> Void) {
        _holdFlags = State(initialValue: initial.holdFlags)
        _tapEscape = State(initialValue: initial.tapEmitsEscape)
        self.onChange = onChange
    }

    private var modifiers: HotkeyModifiers { HotkeyModifiers(rawValue: holdFlags) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                DSKeycap(label: "caps lock") {
                    Image(systemName: "capslock.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.dsMuted)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsAccent.opacity(0.7))
                VStack(alignment: .leading, spacing: 6) {
                    DSSectionLabel("Hold acts as")
                    Text(modifiers.symbols.isEmpty ? "nothing" : modifiers.symbols)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(modifiers.symbols.isEmpty ? Color.dsFaint : Color.dsAccent)
                        .dsContentCrossfade(modifiers.symbols)
                }
            }
            HStack(spacing: 8) {
                DSChip(title: "\u{2726} Hyper", selected: modifiers == .hyper) {
                    setFlags(HotkeyModifiers.hyper)
                }
                DSChip(title: "\u{2318} Command", selected: modifiers == [.command]) {
                    setFlags([.command])
                }
            }
            HStack(spacing: 14) {
                modifierCheckbox("\u{2318} Command", .command)
                modifierCheckbox("\u{2325} Option", .option)
                modifierCheckbox("\u{2303} Control", .control)
                modifierCheckbox("\u{21E7} Shift", .shift)
            }
            DSToggleRow(
                title: "Tap alone sends Escape",
                caption: "A quick press with no other key acts as the Escape key.",
                isOn: Binding(
                    get: { tapEscape },
                    set: { tapEscape = $0; commit() }))
            Text("The \u{2726} hyper layer (all four modifiers) is free real estate: no app ships shortcuts on it, so it is yours for global hotkeys. Applied while this module is on; removed when off or the app quits.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dsFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modifierCheckbox(_ label: String, _ modifier: HotkeyModifiers) -> some View {
        HStack(spacing: 6) {
            DSCheckbox(isOn: Binding(
                get: { modifiers.contains(modifier) },
                set: { on in
                    var m = modifiers
                    if on { m.insert(modifier) } else { m.remove(modifier) }
                    setFlags(m)
                }))
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.dsPaper)
        }
    }

    private func setFlags(_ m: HotkeyModifiers) {
        holdFlags = m.rawValue
        commit()
    }

    private func commit() {
        onChange(HyperKeyMapper.Config(holdFlags: holdFlags, tapEmitsEscape: tapEscape))
    }
}
