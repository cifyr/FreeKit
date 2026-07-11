import AppKit
import SwiftUI
import FreeSpeechCore

// The suite's own always-visible menu bar item: one door into the control
// center that survives every per-module visibility toggle.
final class SuiteStatusItem: NSObject {
    private let statusItem: NSStatusItem
    private let onOpenControlCenter: () -> Void

    init(onOpenControlCenter: @escaping () -> Void) {
        self.onOpenControlCenter = onOpenControlCenter
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "square.grid.2x2", accessibilityDescription: "FreeKit")
            button.toolTip = "FreeKit"
        }
        let menu = NSMenu()
        let open = NSMenuItem(
            title: "Open FreeKit\u{2026}", action: #selector(openControlCenter), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FreeKit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func openControlCenter() {
        onOpenControlCenter()
    }

    @objc private func quitApp() {
        Log.info("quit requested from suite menu")
        NSApp.terminate(nil)
    }
}

final class ControlCenterWindowController {
    private var window: NSWindow?
    private let registry: ModuleRegistry

    init(registry: ModuleRegistry) {
        self.registry = registry
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: ControlCenterView(registry: registry))
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            w.title = "FreeKit"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)  // Greenlight is dark-only
            w.backgroundColor = DS.ink0
            w.minSize = NSSize(width: 560, height: 480)
            w.setContentSize(NSSize(width: 600, height: 720))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("control center opened")
    }
}

// One card per module: enable toggle, menu-bar toggle, disclosure into the
// module's inline settings pane. Coming-soon tools render greyed with a badge.
struct ControlCenterView: View {
    @ObservedObject var registry: ModuleRegistry
    @State private var expandedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FREEKIT")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(Color.dsAccent)
                Text("Control Center")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(Color.dsPaper)
                Text("One process, one menu bar, many small tools. Enable what you use.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dsMuted)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(registry.modules.map(\.info)) { info in
                        ModuleCard(
                            registry: registry,
                            info: info,
                            expanded: expandedID == info.id,
                            onToggleExpanded: {
                                withAnimation(.easeOut(duration: DS.durBase)) {
                                    expandedID = expandedID == info.id ? nil : info.id
                                }
                            })
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 600, maxWidth: .infinity,
               minHeight: 480, idealHeight: 720, maxHeight: .infinity)
        .background(Color.dsInk0)
    }
}

private struct ModuleCard: View {
    @ObservedObject var registry: ModuleRegistry
    let info: ModuleInfo
    let expanded: Bool
    let onToggleExpanded: () -> Void
    @State private var hovering = false

    private var comingSoon: Bool { info.status == .comingSoon }
    private var enabled: Bool { registry.isEnabled(id: info.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: info.symbolName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(
                        comingSoon ? Color.dsFaint : (enabled ? Color.dsAccent : Color.dsMuted))
                    .frame(width: 38, height: 38)
                    .background(
                        Color.dsInk2,
                        in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous)
                            .strokeBorder(Color.dsLine, lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(info.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(comingSoon ? Color.dsFaint : Color.dsPaper)
                        if comingSoon {
                            Text("COMING SOON")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .kerning(1.0)
                                .foregroundStyle(Color.dsFaint)
                                .padding(.horizontal, 7)
                                .frame(height: 18)
                                .background(Color.dsInk2, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
                        }
                    }
                    Text(info.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(comingSoon ? Color.dsFaint : Color.dsMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if !comingSoon {
                    toggleColumn(
                        label: "ON",
                        isOn: Binding(
                            get: { registry.isEnabled(id: info.id) },
                            set: { registry.setEnabled($0, id: info.id) }))
                    if info.ownsMenuBarItem {
                        toggleColumn(
                            label: "MENU BAR",
                            isOn: Binding(
                                get: { registry.showsMenuBarItem(id: info.id) },
                                set: { registry.setShowsMenuBarItem($0, id: info.id) }))
                        .opacity(enabled ? 1 : 0.4)
                        .disabled(!enabled)
                    }
                    Button {
                        onToggleExpanded()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dsMuted)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .frame(width: 26, height: 26)
                            .background(
                                hovering ? Color(nsColor: DS.controlHover) : Color.clear,
                                in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            if expanded, !comingSoon, let module = registry.module(id: info.id) {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(Color.dsLine)
                        .frame(height: 1)
                    module.makeSettingsPane()
                        .padding(16)
                }
                .transition(.opacity)
            }
        }
        .background(
            Color.dsInk1,
            in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(Color.dsLine, lineWidth: 1))
        .opacity(comingSoon ? 0.55 : 1)
        .onHover { hovering = $0 }
    }

    private func toggleColumn(label: String, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 5) {
            DSCheckbox(isOn: isOn)
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .kerning(0.8)
                .foregroundStyle(Color.dsFaint)
        }
        .frame(minWidth: 44)
    }
}
