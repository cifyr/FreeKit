import Foundation

// Decision logic for the Caps Lock remap. The app layer remaps Caps Lock to F18
// at the HID level (hidutil), because a session event tap cannot observe caps
// press/release: the toggle happens below the tap. F18 then behaves like a real
// key with clean down/up events, and this mapper decides what each event becomes.
public final class HyperKeyMapper {
    // Fully user-composable: any modifier mix while held, optional Escape on a
    // lone tap. Hyper and Command are just preset flag values.
    public struct Config: Equatable {
        public var holdFlags: UInt64
        public var tapEmitsEscape: Bool

        public init(holdFlags: UInt64, tapEmitsEscape: Bool) {
            self.holdFlags = holdFlags
            self.tapEmitsEscape = tapEmitsEscape
        }

        public static let hyper = Config(
            holdFlags: HyperKeyMapper.hyperFlags, tapEmitsEscape: false)
        public static let command = Config(
            holdFlags: HotkeyModifiers.command.rawValue, tapEmitsEscape: false)
    }

    public enum KeyAction: Equatable {
        case pass
        case swallow
        case rewriteFlags(UInt64)
        case swallowAndEmitEscape
    }

    // Cmd+Opt+Ctrl+Shift: a modifier layer no app ships defaults for.
    public static let hyperFlags: UInt64 = HotkeyModifiers.hyper.rawValue

    // Slow enough for a deliberate tap, fast enough that holding for a chord
    // never fires a stray Escape.
    public static let tapTimeout: TimeInterval = 0.4

    public private(set) var config: Config
    public private(set) var triggerIsDown = false
    private var downTime: TimeInterval = 0
    private var chordedWhileDown = false

    public init(config: Config) {
        self.config = config
    }

    public func reset(config: Config) {
        self.config = config
        triggerIsDown = false
        chordedWhileDown = false
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
        if config.tapEmitsEscape, !chordedWhileDown, time - downTime < Self.tapTimeout {
            return .swallowAndEmitEscape
        }
        return .swallow
    }

    // Every non-trigger key event while the trigger is held gets the configured
    // modifier flags added, so apps see e.g. Hyper+K as one chord.
    public func handleOtherKey(flags: UInt64) -> KeyAction {
        guard triggerIsDown else { return .pass }
        chordedWhileDown = true
        return .rewriteFlags(flags | config.holdFlags)
    }
}
