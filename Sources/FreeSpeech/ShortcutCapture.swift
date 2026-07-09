import AppKit
import FreeSpeechCore

// Reusable global-chord capture: records the next keypress, combo (Cmd+K, Cmd+Opt+Space),
// or bare modifier (press and release it alone) as a HotkeyPreset. Esc cancels.
final class ShortcutCapture {
    private var monitor: Any?
    private var involvedModifiers: Set<Int64> = []
    private var onResult: ((HotkeyPreset) -> Void)?

    var isCapturing: Bool { monitor != nil }

    func begin(_ onResult: @escaping (HotkeyPreset) -> Void) {
        guard monitor == nil else { return }
        self.onResult = onResult
        involvedModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let code = Int64(event.keyCode)
            switch event.type {
            case .keyDown:
                if code == 53 { self.end(); return nil }  // Esc cancels
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
            default:
                return event
            }
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        involvedModifiers = []
        onResult = nil
    }

    private func finish(_ keyCode: Int64, _ modifiers: HotkeyModifiers) {
        let callback = onResult
        end()
        callback?(HotkeyPreset.custom(keyCode: keyCode, modifiers: modifiers))
    }
}
