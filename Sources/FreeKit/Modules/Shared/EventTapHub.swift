import AppKit
import FreeKitCore

enum EventTapError: LocalizedError {
    case tapCreationFailed

    var errorDescription: String? {
        "Could not install the global hotkey listener — Accessibility permission is required"
    }
}

// A module that rewrites raw keyboard events (the HyperKey remap). Runs before
// hotkey matching so remapped flags are what recognizers see.
protocol EventRewriter: AnyObject {
    // May mutate the event in place; return .swallow to drop it entirely.
    func rewrite(kind: HotkeyRecognizer.EventKind, event: CGEvent) -> EventRewriteVerdict
}

enum EventRewriteVerdict {
    case pass
    case swallow
}

// The suite's single active CGEventTap. One tap instead of one per hotkey: taps
// are a scarce, failure-prone resource (macOS disables stalled ones), and
// multiple active taps ordering against each other is undefined. All global
// hotkeys and the HyperKey remap funnel through here.
final class EventTapHub {
    final class HotkeyToken {
        fileprivate let recognizer: HotkeyRecognizer
        fileprivate let onEvent: (HotkeyRecognizer.Direction) -> Void
        fileprivate let label: String

        fileprivate init(recognizer: HotkeyRecognizer, label: String,
                         onEvent: @escaping (HotkeyRecognizer.Direction) -> Void) {
            self.recognizer = recognizer
            self.label = label
            self.onEvent = onEvent
        }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tokens: [HotkeyToken] = []
    private var rewriters: [EventRewriter] = []

    var isRunning: Bool { tap != nil }

    // Registrations are accepted any time; they take effect once the tap starts
    // (Accessibility can be granted after launch).
    func register(preset: HotkeyPreset, label: String,
                  onEvent: @escaping (HotkeyRecognizer.Direction) -> Void) -> HotkeyToken {
        let token = HotkeyToken(
            recognizer: HotkeyRecognizer(preset: preset), label: label, onEvent: onEvent)
        tokens.append(token)
        Log.info("hotkey registered: \(label) = \(preset.displayName) [keyCode \(preset.keyCode)]")
        return token
    }

    func unregister(_ token: HotkeyToken) {
        tokens.removeAll { $0 === token }
    }

    func update(_ token: HotkeyToken, preset: HotkeyPreset) {
        token.recognizer.reset(preset: preset)
        Log.info("hotkey updated: \(token.label) = \(preset.displayName) [keyCode \(preset.keyCode)]")
    }

    func addRewriter(_ rewriter: EventRewriter) {
        guard !rewriters.contains(where: { $0 === rewriter }) else { return }
        rewriters.append(rewriter)
    }

    func removeRewriter(_ rewriter: EventRewriter) {
        rewriters.removeAll { $0 === rewriter }
    }

    func start() throws {
        guard tap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        // Active (not listen-only) tap: hotkey key events must be swallowed so a
        // combo like Cmd+K never reaches the frontmost app. Everything else passes.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let hub = Unmanaged<EventTapHub>.fromOpaque(userInfo).takeUnretainedValue()
                return hub.handle(type: type, event: event)
                    ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            throw EventTapError.tapCreationFailed
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("event tap hub started (\(tokens.count) hotkeys, \(rewriters.count) rewriters)")
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    // Returns true when the event must not reach other apps.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables taps that stall or when the user triggers Secure Input;
        // re-enabling here is what keeps the hotkeys firing forever.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                Log.error("event tap disabled by system (\(type.rawValue)), re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        let kind: HotkeyRecognizer.EventKind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return false
        }

        // Rewriters (the HyperKey Caps Lock -> Hyper remap) must keep running even while
        // a recorder is capturing: the recorder's local NSEvent monitor only
        // sees Hyper-key chords because this rewrite already folded the hold
        // flags in. Skipping it here made Hyper combos impossible to record.
        for rewriter in rewriters {
            if case .swallow = rewriter.rewrite(kind: kind, event: event) {
                return true
            }
        }

        // The focused recorder's local monitor must receive the (possibly
        // rewritten) event, but no already-registered hotkey may fire while
        // it's active — otherwise recording a new binding could trigger an
        // old one mid-capture.
        if ShortcutCaptureGate.isActive {
            for token in tokens {
                token.recognizer.reset(preset: token.recognizer.preset)
            }
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // Every recognizer sees every event so their held-state machines stay
        // consistent; the event is swallowed if any of them claims it.
        var swallow = false
        for token in tokens {
            switch token.recognizer.handle(
                kind: kind, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat) {
            case .pass:
                break
            case .swallow:
                swallow = true
            case .fire(let direction, let swallowEvent):
                swallow = swallow || swallowEvent
                dispatch(token, direction)
            }
        }
        return swallow
    }

    private func dispatch(_ token: HotkeyToken, _ direction: HotkeyRecognizer.Direction) {
        Log.info("hotkey fired: \(token.label) \(direction)")
        DispatchQueue.main.async {
            token.onEvent(direction)
        }
    }
}
