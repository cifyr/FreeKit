import AppKit
import ApplicationServices
import FreeSpeechCore

// Learns from the user's edits: snapshots the focused text field just after
// insertion, again after a settling delay, and diffs the two. Runs entirely
// after the hot path, so dictation latency is unaffected. Fields that do not
// expose text over AX (terminals, some Electron apps) are skipped quietly.
final class EditWatcher {
    private static let baselineDelay: TimeInterval = 1.0
    private static let settleDelay: TimeInterval = 20.0

    private let store: LearningStore
    private var pending: [DispatchWorkItem] = []

    init(store: LearningStore) {
        self.store = store
    }

    func watch(inserted: String) {
        // A new dictation supersedes any in-flight watch.
        pending.forEach { $0.cancel() }
        pending.removeAll()

        let baseline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let element = Self.focusedElement(), let before = Self.value(of: element) else {
                Log.info("edit learning: focused field not readable over AX, skipping")
                return
            }
            guard before.contains(inserted.prefix(24)) else {
                Log.info("edit learning: inserted text not found in focused field, skipping")
                return
            }
            let settle = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Same element re-read later: survives the user focusing elsewhere.
                guard let after = Self.value(of: element), after != before else { return }
                let pairs = EditDiff.corrections(inserted: inserted, before: before, after: after)
                guard !pairs.isEmpty else { return }
                for (from, to) in pairs {
                    Log.info("edit learning: observed correction \"\(from)\" -> \"\(to)\"")
                }
                self.store.recordCorrections(pairs)
            }
            self.pending.append(settle)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: settle)
        }
        pending.append(baseline)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.baselineDelay, execute: baseline)
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value)
        guard status == .success, let text = value as? String, !text.isEmpty else { return nil }
        // Very large documents make diffing meaningless; EditDiff also guards on words.
        return text.count > 60_000 ? nil : text
    }
}
