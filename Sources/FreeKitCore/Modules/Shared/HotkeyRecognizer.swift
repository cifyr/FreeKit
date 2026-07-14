import Foundation

// The hotkey-matching state machine extracted from the app's event tap so it is
// unit-testable and so one shared tap can host many hotkeys. Semantics are the
// original HotkeyManager's: hold support for bare modifiers, autorepeat
// swallowing while a combo is held, and modifier-release-before-key handling.
public final class HotkeyRecognizer {
    public enum EventKind: Equatable {
        case flagsChanged
        case keyDown
        case keyUp
    }

    public enum Direction: Equatable { case down, up }

    public enum Verdict: Equatable {
        case pass
        case swallow
        // fire always implies the event's fate; bare-modifier flag changes stay
        // visible to the system (harmless alone), key events are swallowed.
        case fire(Direction, swallow: Bool)
    }

    public private(set) var preset: HotkeyPreset
    private var modifierIsDown = false
    private var comboIsDown = false
    // The combo ended by modifier release but the key is still physically down:
    // its remaining repeats and final key-up must not leak to the app.
    private var awaitingKeyUp = false

    public init(preset: HotkeyPreset) {
        self.preset = preset
    }

    public func reset(preset: HotkeyPreset) {
        self.preset = preset
        modifierIsDown = false
        comboIsDown = false
        awaitingKeyUp = false
    }

    public func handle(kind: EventKind, keyCode: Int64, flags: UInt64,
                       isAutorepeat: Bool) -> Verdict {
        let relevant = flags & HotkeyModifiers.all.rawValue
        let required = preset.modifiers.rawValue

        switch (preset.kind, kind) {
        case (.modifier, .flagsChanged):
            guard keyCode == preset.keyCode else { return .pass }
            let flagBit = Self.flagBit(forKeyCode: preset.keyCode)
            let isDown = (flags & flagBit) != 0
            guard isDown != modifierIsDown else { return .pass }  // debounce duplicate flag events
            modifierIsDown = isDown
            return .fire(isDown ? .down : .up, swallow: false)

        case (.key, .keyDown):
            guard keyCode == preset.keyCode else { return .pass }
            // While the combo is held (push-to-talk), the key autorepeats: every
            // one of those must be swallowed or the app underneath receives a
            // stream of e.g. Cmd+= presses while the user is dictating.
            if comboIsDown || awaitingKeyUp { return .swallow }
            guard relevant == required else { return .pass }
            guard !isAutorepeat else { return .swallow }
            comboIsDown = true
            return .fire(.down, swallow: true)

        case (.key, .keyUp):
            guard keyCode == preset.keyCode else { return .pass }
            if awaitingKeyUp {
                awaitingKeyUp = false
                return .swallow
            }
            guard comboIsDown else { return .pass }
            comboIsDown = false
            return .fire(.up, swallow: true)

        case (.key, .flagsChanged):
            // Push-to-talk on a combo: releasing a required modifier before the key
            // (e.g. Cmd before = in Cmd+=) must still count as release, and the
            // still-held key is then muted until its own key-up.
            if comboIsDown, (relevant & required) != required {
                comboIsDown = false
                awaitingKeyUp = true
                return .fire(.up, swallow: false)
            }
            return .pass

        default:
            return .pass
        }
    }

    // CGEventFlags bits for each physical modifier key code.
    public static func flagBit(forKeyCode keyCode: Int64) -> UInt64 {
        switch keyCode {
        case 54, 55: return HotkeyModifiers.command.rawValue
        case 58, 61: return HotkeyModifiers.option.rawValue
        case 56, 60: return HotkeyModifiers.shift.rawValue
        case 59, 62: return HotkeyModifiers.control.rawValue
        case 63: return HotkeyModifiers.fn.rawValue
        default: return 0
        }
    }
}
