import AppKit
import ApplicationServices
import Foundation
import FreeKitCore

// Shared AX access to the focused text field, used by EditWatcher (learning)
// and TextInserter (caret context). Every read fails soft: nil means "field
// not readable", and callers fall back to their plain behavior.
enum AXFieldReader {
    // The insert-time read sits on the hot path; a stuck AX server (busy app)
    // must never delay the paste beyond this.
    private static let readTimeout: TimeInterval = 0.15
    private static let maxFieldChars = 60_000
    private static let queue = DispatchQueue(
        label: "com.cadenwarren.freespeech.axread", qos: .userInitiated)

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value)
        guard status == .success, let text = value as? String, !text.isEmpty else { return nil }
        // Very large documents make diffing/context meaningless.
        return text.count > maxFieldChars ? nil : text
    }

    // Text before the caret in the focused field, tail-capped. Runs on a worker
    // queue with a hard timeout so insertion can never hang on a stalled AX call.
    static func textBeforeCaret(maxChars: Int = 400) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        queue.async {
            defer { semaphore.signal() }
            guard let element = focusedElement(),
                  let text = value(of: element),
                  let caret = caretLocation(of: element) else { return }
            let clamped = min(max(0, caret), text.count)
            let start = text.index(text.startIndex, offsetBy: max(0, clamped - maxChars))
            let end = text.index(text.startIndex, offsetBy: clamped)
            result = String(text[start..<end])
        }
        if semaphore.wait(timeout: .now() + readTimeout) == .timedOut {
            Log.info("AX caret read timed out after \(Int(readTimeout * 1000))ms, using plain insert")
            return nil
        }
        return result
    }

    // Focused field text plus the frontmost window title: the context a person
    // sees when dictating (email thread, chat, document). Bounded like the caret
    // read; nil when nothing is readable.
    static func screenContextText() -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        queue.async {
            defer { semaphore.signal() }
            var parts: [String] = []
            if let element = focusedElement(), let text = value(of: element) {
                parts.append(String(text.suffix(4000)))
            }
            if let title = frontmostWindowTitle() {
                parts.append(title)
            }
            result = parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if semaphore.wait(timeout: .now() + readTimeout) == .timedOut {
            Log.info("AX screen context read timed out, skipping context terms")
            return nil
        }
        return result
    }

    private static func frontmostWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            (window as! AXUIElement), kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }

    private static func caretLocation(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range.location
    }
}
