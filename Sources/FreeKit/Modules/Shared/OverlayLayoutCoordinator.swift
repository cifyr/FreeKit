import AppKit
import Combine

// Shared geometry for top-of-screen surfaces. Both modules publish their live
// bounds here, so either can move before an expansion would cover the other.
final class OverlayLayoutCoordinator: ObservableObject {
    static let shared = OverlayLayoutCoordinator()

    @Published private(set) var notchFrame: NSRect = .zero
    @Published private(set) var notchExpanded = false
    @Published private(set) var menuShelfFrame: NSRect = .zero
    @Published private(set) var menuTriggerFrame: NSRect = .zero
    @Published private(set) var menuBarActive = false

    func updateNotch(frame: NSRect, expanded: Bool) {
        notchFrame = frame
        notchExpanded = expanded
    }

    func clearNotch() {
        notchFrame = .zero
        notchExpanded = false
    }

    func updateMenuShelf(frame: NSRect) {
        menuShelfFrame = frame
    }

    func clearMenuShelf() {
        menuShelfFrame = .zero
    }

    func updateMenuTrigger(frame: NSRect) {
        menuTriggerFrame = frame
    }

    func clearMenuTrigger() {
        menuTriggerFrame = .zero
    }

    func setMenuBarActive(_ active: Bool) {
        menuBarActive = active
        if !active { menuTriggerFrame = .zero }
    }
}
