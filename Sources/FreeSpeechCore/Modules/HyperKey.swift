import Foundation

// Decision logic for the Caps Lock remap. The app layer remaps Caps Lock to F18
// at the HID level (hidutil), because a session event tap cannot observe caps
// press/release: the toggle happens below the tap. F18 then behaves like a real
// key with clean down/up events, and this mapper decides what each event becomes.
public final class HyperKeyMapper {
    public enum Behavior: String, CaseIterable {
        // Caps Lock held = Cmd+Opt+Ctrl+Shift, a modifier no app ships defaults for.
        case hyper
        case command
        // Tap alone = Escape, hold with another key = hyper.
        case escapeTapHyperHold

        public var displayName: String {
            switch self {
            case .hyper: return "Hyper key"
            case .command: return "Command"
            case .escapeTapHyperHold: return "Tap Escape / hold Hyper"
            }
        }
    }

    public enum KeyAction: Equatable {
        case pass
        case swallow
        case rewriteFlags(UInt64)
        case swallowAndEmitEscape
    }

    public static let hyperFlags: UInt64 =
        HotkeyModifiers.command.rawValue | HotkeyModifiers.option.rawValue
        | HotkeyModifiers.control.rawValue | HotkeyModifiers.shift.rawValue

    // Slow enough for a deliberate tap, fast enough that holding for a chord
    // never fires a stray Escape.
    public static let tapTimeout: TimeInterval = 0.4

    public private(set) var behavior: Behavior
    public private(set) var triggerIsDown = false
    private var downTime: TimeInterval = 0
    private var chordedWhileDown = false

    public init(behavior: Behavior) {
        self.behavior = behavior
    }

    public func reset(behavior: Behavior) {
        self.behavior = behavior
        triggerIsDown = false
        chordedWhileDown = false
    }

    private var activeFlags: UInt64 {
        switch behavior {
        case .hyper, .escapeTapHyperHold: return Self.hyperFlags
        case .command: return HotkeyModifiers.command.rawValue
        }
    }

    public func handleTriggerDown(at time: TimeInterval) -> KeyAction {
        // Autorepeat of the held trigger must not reset the tap timer.
        if triggerIsDown { return .swallow }
        triggerIsDown = true
        chordedWhileDown = false
        downTime = time
        return .swallow
    }

    public func handleTriggerUp(at time: TimeInterval) -> KeyAction {
        triggerIsDown = false
        if behavior == .escapeTapHyperHold, !chordedWhileDown,
           time - downTime < Self.tapTimeout {
            return .swallowAndEmitEscape
        }
        return .swallow
    }

    // Every non-trigger key event while the trigger is held gets the mapped
    // modifier flags added, so apps see e.g. Hyper+K as one chord.
    public func handleOtherKey(flags: UInt64) -> KeyAction {
        guard triggerIsDown else { return .pass }
        chordedWhileDown = true
        return .rewriteFlags(flags | activeFlags)
    }
}
