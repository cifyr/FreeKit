import AppKit
import FreeKitCore

// While any recorder owns a session, the global event tap bypasses every
// registered shortcut so recording a new chord can never trigger an old one.
enum ShortcutCaptureGate {
    private static var sessions: Set<UUID> = []

    static var isActive: Bool { !sessions.isEmpty }

    static func activate() -> UUID {
        let id = UUID()
        sessions.insert(id)
        return id
    }

    static func deactivate(_ id: UUID?) {
        guard let id else { return }
        sessions.remove(id)
    }
}

// Reusable chord capture: records a keypress, combo, or bare modifier. Escape
// clears the binding; clicking elsewhere cancels without changing it.
final class ShortcutCapture {
    private var monitor: Any?
    private var globalMouseMonitor: Any?
    private var involvedModifiers: Set<Int64> = []
    private var onResult: ((HotkeyPreset) -> Void)?
    private var onClear: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var gateSession: UUID?

    var isCapturing: Bool { monitor != nil }

    func begin(_ onResult: @escaping (HotkeyPreset) -> Void) {
        begin(onSet: onResult, onClear: {}, onCancel: {})
    }

    func begin(
        onSet: @escaping (HotkeyPreset) -> Void,
        onClear: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard monitor == nil else { return }
        self.onResult = onSet
        self.onClear = onClear
        self.onCancel = onCancel
        involvedModifiers = []
        gateSession = ShortcutCaptureGate.activate()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]) { [weak self] event in
            guard let self else { return event }
            let code = Int64(event.keyCode)
            switch event.type {
            case .keyDown:
                if code == 53 { self.clear(); return nil }
                let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
                var mods: HotkeyModifiers = []
                if flags.contains(.command) { mods.insert(.command) }
                if flags.contains(.option) { mods.insert(.option) }
                if flags.contains(.shift) { mods.insert(.shift) }
                if flags.contains(.control) { mods.insert(.control) }
                self.finish(code, mods)
                return nil
            case .flagsChanged:
                guard KeyNames.isModifier(code) else { return event }
                let anyHeld = !event.modifierFlags
                    .intersection([.command, .option, .shift, .control, .function]).isEmpty
                if anyHeld {
                    self.involvedModifiers.insert(code)
                } else {
                    // Released with no regular key: a single involved modifier is the choice.
                    if self.involvedModifiers.count == 1, let only = self.involvedModifiers.first {
                        self.finish(only, [])
                    }
                    self.involvedModifiers = []
                }
                return event
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                self.cancel()
                return event
            default:
                return event
            }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]) { [weak self] _ in
            DispatchQueue.main.async { self?.cancel() }
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        monitor = nil
        globalMouseMonitor = nil
        involvedModifiers = []
        onResult = nil
        onClear = nil
        onCancel = nil
        ShortcutCaptureGate.deactivate(gateSession)
        gateSession = nil
    }

    private func finish(_ keyCode: Int64, _ modifiers: HotkeyModifiers) {
        let callback = onResult
        end()
        callback?(HotkeyPreset.custom(keyCode: keyCode, modifiers: modifiers))
    }

    private func clear() {
        let callback = onClear
        end()
        callback?()
    }

    private func cancel() {
        let callback = onCancel
        end()
        callback?()
    }
}
