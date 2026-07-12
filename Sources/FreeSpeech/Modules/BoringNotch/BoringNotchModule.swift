import AppKit
import Combine
import IOKit.ps
import SwiftUI
import UniformTypeIdentifiers
import FreeSpeechCore

final class BoringNotchPreferences: ObservableObject {
    static let shared = BoringNotchPreferences()

    private enum Key {
        static let collapsedWidth = "notch.collapsedWidth"
        static let expandedWidth = "notch.expandedWidth"
        static let expandedHeight = "notch.expandedHeight"
        static let expandOnHover = "notch.expandOnHover"
        static let autoCollapse = "notch.autoCollapse"
        static let showClock = "notch.showClock"
        static let showActiveApp = "notch.showActiveApp"
        static let showQuickTools = "notch.showQuickTools"
        static let showBattery = "notch.showBattery"
        static let showFileShelf = "notch.showFileShelf"
        static let showAccent = "notch.showAccent"
        static let quickToolCount = "notch.quickToolCount"
        static let collapseDelay = "notch.collapseDelay"
        static let cornerRadius = "notch.cornerRadius"
    }

    private let defaults: UserDefaults

    @Published var collapsedWidth: Double { didSet { defaults.set(collapsedWidth, forKey: Key.collapsedWidth) } }
    @Published var expandedWidth: Double { didSet { defaults.set(expandedWidth, forKey: Key.expandedWidth) } }
    @Published var expandedHeight: Double { didSet { defaults.set(expandedHeight, forKey: Key.expandedHeight) } }
    @Published var expandOnHover: Bool { didSet { defaults.set(expandOnHover, forKey: Key.expandOnHover) } }
    @Published var autoCollapse: Bool { didSet { defaults.set(autoCollapse, forKey: Key.autoCollapse) } }
    @Published var showClock: Bool { didSet { defaults.set(showClock, forKey: Key.showClock) } }
    @Published var showActiveApp: Bool { didSet { defaults.set(showActiveApp, forKey: Key.showActiveApp) } }
    @Published var showQuickTools: Bool { didSet { defaults.set(showQuickTools, forKey: Key.showQuickTools) } }
    @Published var showBattery: Bool { didSet { defaults.set(showBattery, forKey: Key.showBattery) } }
    @Published var showFileShelf: Bool { didSet { defaults.set(showFileShelf, forKey: Key.showFileShelf) } }
    @Published var showAccent: Bool { didSet { defaults.set(showAccent, forKey: Key.showAccent) } }
    @Published var quickToolCount: Int { didSet { defaults.set(quickToolCount, forKey: Key.quickToolCount) } }
    @Published var collapseDelay: Double { didSet { defaults.set(collapseDelay, forKey: Key.collapseDelay) } }
    @Published var cornerRadius: Double { didSet { defaults.set(cornerRadius, forKey: Key.cornerRadius) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsedWidth = defaults.object(forKey: Key.collapsedWidth) as? Double ?? 220
        expandedWidth = defaults.object(forKey: Key.expandedWidth) as? Double ?? 430
        expandedHeight = defaults.object(forKey: Key.expandedHeight) as? Double ?? 150
        expandOnHover = defaults.object(forKey: Key.expandOnHover) as? Bool ?? true
        autoCollapse = defaults.object(forKey: Key.autoCollapse) as? Bool ?? true
        showClock = defaults.object(forKey: Key.showClock) as? Bool ?? true
        showActiveApp = defaults.object(forKey: Key.showActiveApp) as? Bool ?? true
        showQuickTools = defaults.object(forKey: Key.showQuickTools) as? Bool ?? true
        showBattery = defaults.object(forKey: Key.showBattery) as? Bool ?? true
        showFileShelf = defaults.object(forKey: Key.showFileShelf) as? Bool ?? true
        showAccent = defaults.object(forKey: Key.showAccent) as? Bool ?? true
        quickToolCount = defaults.object(forKey: Key.quickToolCount) as? Int ?? 6
        collapseDelay = defaults.object(forKey: Key.collapseDelay) as? Double ?? 0.8
        cornerRadius = defaults.object(forKey: Key.cornerRadius) as? Double ?? 22
    }
}

final class BoringNotchModule: AppModule {
    let info = ModuleCatalog.boringNotch

    private let registry: ModuleRegistry
    private let preferences = BoringNotchPreferences.shared
    private let coordinator = OverlayLayoutCoordinator.shared
    private lazy var controller = BoringNotchPanelController(
        registry: registry,
        preferences: preferences,
        coordinator: coordinator)
    private lazy var settingsWindow = ModuleSettingsWindowController(
        info: info,
        contentSize: NSSize(width: 580, height: 650),
        minimumSize: NSSize(width: 520, height: 420)
    ) { [registry] in
        AnyView(BoringNotchSettingsPane(registry: registry))
    }

    init(registry: ModuleRegistry) {
        self.registry = registry
    }

    func activate() { controller.show() }
    func deactivate() { controller.hide() }
    func setMenuBarItemVisible(_ visible: Bool) {}
    var settingsStyle: ModuleSettingsStyle { .window }
    func makeSettingsPane() -> AnyView { AnyView(BoringNotchSettingsPane(registry: registry)) }
    func openSettings() { settingsWindow.show() }
}

final class BoringNotchPanelController {
    private let panel: NSPanel
    private let registry: ModuleRegistry
    private let preferences: BoringNotchPreferences
    private let coordinator: OverlayLayoutCoordinator
    private var subscriptions: Set<AnyCancellable> = []
    private var collapseWork: DispatchWorkItem?
    private let state = BoringNotchPanelState()
    private var isExpanded: Bool { state.expanded }

    init(
        registry: ModuleRegistry,
        preferences: BoringNotchPreferences,
        coordinator: OverlayLayoutCoordinator
    ) {
        self.registry = registry
        self.preferences = preferences
        self.coordinator = coordinator
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: BoringNotchPanelView(
            registry: registry,
            preferences: preferences,
            state: state,
            onToggle: { [weak self] in self?.setExpanded(!(self?.isExpanded ?? false)) },
            onHover: { [weak self] hovering in self?.handleHover(hovering) },
            onOpen: { [weak self] module in self?.open(module) }))

        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateFrame(animated: true) }
        }.store(in: &subscriptions)
    }

    func show() {
        updateFrame(animated: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        collapseWork?.cancel()
        panel.orderOut(nil)
        coordinator.clearNotch()
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        collapseWork?.cancel()
        state.expanded = expanded
        updateFrame(animated: true)
    }

    private func handleHover(_ hovering: Bool) {
        guard preferences.expandOnHover else { return }
        collapseWork?.cancel()
        if hovering {
            setExpanded(true)
        } else if preferences.autoCollapse {
            let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    private func open(_ module: AppModule) {
        if !registry.isEnabled(id: module.info.id) {
            registry.setEnabled(true, id: module.info.id)
        }
        module.openSettings()
        if preferences.autoCollapse { setExpanded(false) }
    }

    private func updateFrame(animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let collapsedHeight = max(30, screen.safeAreaInsets.top)
        let centerX = screen.frame.midX
        var expandedWidth = max(320, min(720, preferences.expandedWidth))
        let trigger = coordinator.menuTriggerFrame
        if coordinator.menuBarActive, trigger.isEmpty {
            expandedWidth = min(expandedWidth, 320)
        } else if !trigger.isEmpty {
            if trigger.midX > centerX {
                expandedWidth = min(expandedWidth, max(320, 2 * (trigger.minX - centerX - 8)))
            } else {
                expandedWidth = min(expandedWidth, max(320, 2 * (centerX - trigger.maxX - 8)))
            }
        }
        let size = isExpanded
            ? NSSize(
                width: expandedWidth,
                height: max(110, min(300, preferences.expandedHeight)))
            : NSSize(
                width: max(140, min(340, preferences.collapsedWidth)),
                height: collapsedHeight)
        let frame = NSRect(
            x: centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height)
        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.durBase
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: panel.isVisible)
        }
        coordinator.updateNotch(frame: frame, expanded: isExpanded)
    }
}

final class BoringNotchPanelState: ObservableObject {
    @Published var expanded = false
}

struct BoringNotchPanelView: View {
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject var preferences: BoringNotchPreferences
    @ObservedObject var state: BoringNotchPanelState
    let onToggle: () -> Void
    let onHover: (Bool) -> Void
    let onOpen: (AppModule) -> Void

    private var quickModules: [AppModule] {
        registry.modules.filter {
            $0.info.status == .available
                && $0.info.id != ModuleCatalog.boringNotch.id
                && registry.isEnabled(id: $0.info.id)
        }
    }

    var body: some View {
        Group {
            if state.expanded { expandedContent } else { collapsedContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: state.expanded ? 22 : 12,
            bottomTrailingRadius: state.expanded ? 22 : 12,
            topTrailingRadius: 0,
            style: .continuous))
        .overlay(UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: state.expanded ? 22 : 12,
            bottomTrailingRadius: state.expanded ? 22 : 12,
            topTrailingRadius: 0,
            style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover(perform: onHover)
    }

    private var collapsedContent: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.dsAccent).frame(width: 5, height: 5)
            Spacer()
            if preferences.showClock {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                if preferences.showClock {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.date, format: .dateTime.hour().minute().second())
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white)
                            Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                    }
                }
                Spacer()
                if preferences.showActiveApp {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("ACTIVE")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.dsAccent)
                        Text(NSWorkspace.shared.frontmostApplication?.localizedName ?? "Desktop")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
            if preferences.showQuickTools {
                HStack(spacing: 8) {
                    ForEach(quickModules.prefix(6), id: \.info.id) { module in
                        Button { onOpen(module) } label: {
                            Image(systemName: module.info.symbolName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.dsAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(Color.white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(module.info.displayName)
                    }
                }
            }
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 34, height: 3)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

struct BoringNotchSettingsPane: View {
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject private var preferences = BoringNotchPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSettingsCard(title: "Preview") {
                BoringNotchPreview(preferences: preferences)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
            }
            DSSettingsCard(title: "Dimensions") {
                slider("Collapsed width", value: $preferences.collapsedWidth, range: 140...340)
                slider("Expanded width", value: $preferences.expandedWidth, range: 320...720)
                slider("Expanded height", value: $preferences.expandedHeight, range: 110...300)
            }
            DSSettingsCard(title: "Behavior") {
                DSToggleRow(title: "Expand on hover", isOn: $preferences.expandOnHover)
                DSToggleRow(title: "Collapse after leaving", isOn: $preferences.autoCollapse)
                DSToggleRow(title: "Show clock", isOn: $preferences.showClock)
                DSToggleRow(title: "Show active app", isOn: $preferences.showActiveApp)
                DSToggleRow(title: "Show FreeKit quick tools", isOn: $preferences.showQuickTools)
            }
        }
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
                .frame(width: 112, alignment: .leading)
            Slider(value: value, in: range).tint(Color.dsAccent)
            Text("\(Int(value.wrappedValue))pt")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.dsMuted)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

private struct BoringNotchPreview: View {
    @ObservedObject var preferences: BoringNotchPreferences

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("9:41")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.white)
                    Text("FREEKIT NOTCH")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dsAccent)
                }
                Spacer()
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            .padding(14)
        }
        .frame(width: min(430, preferences.expandedWidth), height: 100)
        .background(Color.black,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 18,
                        bottomTrailingRadius: 18, topTrailingRadius: 0,
                        style: .continuous))
        .overlay(UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 18,
            bottomTrailingRadius: 18, topTrailingRadius: 0,
            style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}
