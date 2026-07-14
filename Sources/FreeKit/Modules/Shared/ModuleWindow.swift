import AppKit
import Combine
import SwiftUI
import FreeKitCore

// One independent NSWindow per app-like module, generalized from Notebook's
// panel: the Control Center stays the hub for browsing/enabling tools, but an
// app's working UI lives in its own window that outlives the hub being closed.
final class ModuleWindowManager: ObservableObject {
    static let shared = ModuleWindowManager()

    // Modules whose status items key off "is my window open" (Tap, AppCleaner)
    // subscribe to this instead of the Control Center presenter.
    @Published private(set) var visibleModuleIDs: Set<String> = []

    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]

    private init() {}

    func isVisible(moduleID: String) -> Bool {
        visibleModuleIDs.contains(moduleID)
    }

    func open(_ module: AppModule) {
        let id = module.info.id
        let existing = windows[id]
        let window = existing ?? makeWindow(for: module)
        // Fresh pane on every open, matching the Control Center popup, which
        // rebuilt its card per presentation (Convert's Tools-tab routing and
        // per-open state reset both rely on this).
        let priorFrame = existing?.isVisible == true ? existing?.frame : nil
        window.contentViewController = NSHostingController(
            rootView: ModuleWindowRoot(module: module))
        if let priorFrame {
            window.setFrame(priorFrame, display: true)
        } else {
            window.setContentSize(module.settingsPopupSize)
            if !window.setFrameUsingName(Self.autosaveName(id)) { window.center() }
            window.setFrameAutosaveName(Self.autosaveName(id))
        }
        if existing == nil { windows[id] = window }
        visibleModuleIDs.insert(id)
        DSMotionAppKit.presentWindow(window)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("module window: opened \(id)")
    }

    func close(moduleID: String) {
        windows[moduleID]?.close()
    }

    private static func autosaveName(_ id: String) -> String {
        "FreeKit.ModuleWindow.\(id)"
    }

    private func makeWindow(for module: AppModule) -> NSWindow {
        let w = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = module.info.displayName
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = DS.ink0
        w.minSize = NSSize(width: 480, height: 360)
        // Dragging is explicit: the (invisible) titlebar strip plus the
        // WindowDragGesture on AppearanceBackground. Background-drag is off
        // because AppKit's version fought slider/control gestures.
        w.isMovableByWindowBackground = false
        w.isReleasedWhenClosed = false
        let id = module.info.id
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.visibleModuleIDs.remove(id)
            // Drop the pane so per-open UI state resets, same as the popup did.
            self.windows[id]?.contentViewController = nil
            Log.info("module window: closed \(id)")
        }
        return w
    }
}

// Same chrome the in-hub settings card used (kicker + heading + scrolling
// pane + first-run guide), restyled as a full window: the heading is the
// module's name because for app-like tools this window is the app, not a
// settings sheet.
private struct ModuleWindowRoot: View {
    let module: AppModule

    var body: some View {
        Group {
            if module.popupUsesOwnChrome {
                module.makeSettingsPane()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FREEKIT")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .kerning(1.2)
                            .foregroundStyle(Color.dsAccent)
                        Text(module.info.displayName)
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(Color.dsPaper)
                    }
                    ScrollView {
                        module.makeSettingsPane()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 16)
                    }
                }
                .padding(20)
                .moduleGuide(for: module.info)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppearanceBackground())
    }
}
