import AppKit
import Combine
import ServiceManagement
import SwiftUI
import FreeSpeechCore

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
            // Hidden titlebar leaves nothing to grab; drag anywhere instead.
            w.isMovableByWindowBackground = true
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
    @ObservedObject private var appearance = AppearanceManager.shared
    @State private var expandedID: String?
    @State private var selectedSection: Section = .tools

    private enum Section: String, CaseIterable {
        case tools = "Tools"
        case appearance = "Appearance"
        case menuBar = "Menu Bar"
        case roadmap = "Roadmap"
    }

    private var visibleModules: [ModuleInfo] {
        registry.modules.map(\.info).filter {
            selectedSection == .tools ? $0.status == .available : $0.status == .comingSoon
        }
    }

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
                HStack(spacing: 22) {
                    ForEach(Section.allCases, id: \.self) { section in
                        DSTabButton(
                            title: section.rawValue,
                            selected: selectedSection == section
                        ) {
                            selectedSection = section
                            expandedID = nil
                        }
                    }
                    Spacer()
                }
                .padding(.top, 8)
            }
            if selectedSection == .appearance {
                AppearancePane()
            } else if selectedSection == .menuBar {
                MenuBarPane(registry: registry)
            } else {
                ScrollView {
                    LazyVStack(spacing: appearance.density.contentSpacing) {
                        ForEach(visibleModules) { info in
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
            SuitePrefsFooter()
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 600, maxWidth: .infinity,
               minHeight: 480, idealHeight: 720, maxHeight: .infinity)
        .background(AppearanceBackground())
    }
}

private struct MenuBarPane: View {
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject private var appearance = AppearanceManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: appearance.density.contentSpacing) {
                DSSettingsCard(title: "FreeKit Menu") {
                    Text("Choose the suite icon")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dsPaper)
                    HStack(spacing: 8) {
                        ForEach(SuiteMenuIcon.allCases) { option in
                            Button {
                                appearance.suiteMenuIcon = option
                            } label: {
                                VStack(spacing: 7) {
                                    Image(systemName: option.symbolName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(
                                            appearance.suiteMenuIcon == option
                                                ? Color.dsAccent : Color.dsPaper)
                                    Text(option.rawValue)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.dsMuted)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(Color.dsInk2,
                                            in: RoundedRectangle(
                                                cornerRadius: DS.radiusKeycap,
                                                style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous)
                                        .strokeBorder(
                                            appearance.suiteMenuIcon == option
                                                ? Color.dsAccent.opacity(0.6) : Color.dsLine,
                                            lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help("Use the \(option.rawValue.lowercased()) icon")
                        }
                    }
                    DSToggleRow(
                        title: "Quick tool controls",
                        caption: "Show an enable or disable submenu in the FreeKit menu.",
                        isOn: $appearance.suiteMenuQuickTools)
                }

                DSSettingsCard(title: "Module Icons") {
                    ForEach(registry.modules.map(\.info).filter {
                        $0.status == .available && $0.ownsMenuBarItem
                    }) { info in
                        HStack(spacing: 12) {
                            Image(systemName: info.symbolName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(
                                    registry.showsMenuBarItem(id: info.id)
                                        ? Color.dsAccent : Color.dsMuted)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.dsPaper)
                                Text(registry.isEnabled(id: info.id) ? "Tool enabled" : "Tool disabled")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.dsFaint)
                            }
                            Spacer()
                            DSCheckbox(isOn: Binding(
                                get: { registry.showsMenuBarItem(id: info.id) },
                                set: { registry.setShowsMenuBarItem($0, id: info.id) }))
                                .disabled(!registry.isEnabled(id: info.id))
                                .opacity(registry.isEnabled(id: info.id) ? 1 : 0.4)
                        }
                        .frame(minHeight: 34)
                    }
                }

                Text("FreeKit can manage its own status items. macOS does not expose a supported API for rearranging other apps' menu bar items.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dsFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .padding(.bottom, 12)
        }
    }
}

private struct AppearancePane: View {
    @ObservedObject private var appearance = AppearanceManager.shared

    private let accentPresets: [(name: String, hex: String)] = [
        ("Red", "FF453A"),
        ("Orange", "FF9F0A"),
        ("Mint", "63E6BE"),
        ("Blue", "0A84FF"),
        ("Violet", "BF5AF2"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: appearance.density.contentSpacing) {
                preview

                DSSettingsCard(title: "Accent") {
                    HStack(spacing: 10) {
                        ForEach(accentPresets, id: \.hex) { preset in
                            Button {
                                appearance.accentHex = preset.hex
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(nsColor: NSColor(hex: preset.hex) ?? .systemRed))
                                        .frame(width: 25, height: 25)
                                        .overlay(
                                            Circle().strokeBorder(
                                                appearance.accentHex == preset.hex
                                                    ? Color.dsPaper : Color.dsLine,
                                                lineWidth: appearance.accentHex == preset.hex ? 2 : 1))
                                    Text(preset.name)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.dsMuted)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                        ColorPicker("Custom", selection: colorBinding(for: \.accentHex), supportsOpacity: false)
                            .labelsHidden()
                            .help("Choose a custom accent color")
                    }
                }

                DSSettingsCard(title: "Window Gradient") {
                    DSToggleRow(
                        title: "Use gradient backgrounds",
                        caption: "Applied consistently to every FreeKit window.",
                        isOn: $appearance.gradientEnabled)

                    if appearance.gradientEnabled {
                        HStack(spacing: 16) {
                            colorRow("Start", keyPath: \.gradientStartHex)
                            colorRow("End", keyPath: \.gradientEndHex)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            ForEach(AppearanceGradientDirection.allCases) { direction in
                                DSChip(title: direction.rawValue,
                                       selected: appearance.gradientDirection == direction) {
                                    appearance.gradientDirection = direction
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Text("Intensity")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.dsPaper)
                            Slider(value: $appearance.gradientIntensity, in: 0.1...0.85)
                                .tint(Color.dsAccent)
                            Text("\(Int(appearance.gradientIntensity * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.dsMuted)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }

                DSSettingsCard(title: "Interface Shape") {
                    choiceRow("Depth", values: AppearanceDepth.allCases,
                              selected: appearance.depth) { appearance.depth = $0 }
                    choiceRow("Corners", values: AppearanceCornerStyle.allCases,
                              selected: appearance.corners) { appearance.corners = $0 }
                    choiceRow("Density", values: AppearanceDensity.allCases,
                              selected: appearance.density) { appearance.density = $0 }
                }

            }
            .padding(.bottom, 12)
        }
    }

    private var preview: some View {
        HStack(spacing: 14) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.dsAccent)
                .frame(width: 38, height: 38)
                .background(Color.dsInk2,
                            in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Live Preview")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dsPaper)
                Text("Changes are saved automatically and applied across the suite.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsMuted)
            }
            Spacer()
            Button { appearance.reset() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dsMuted)
                    .frame(width: 28, height: 28)
                    .background(Color.dsInk2, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Reset appearance")
            Circle()
                .fill(Color.dsAccent)
                .frame(width: 10, height: 10)
        }
        .padding(appearance.density.cardPadding)
        .background(Color.dsInk1,
                    in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(Color.dsAccent.opacity(0.35), lineWidth: 1))
        .shadow(color: depthShadowColor, radius: depthShadowRadius, y: depthShadowY)
    }

    private func colorRow(_ title: String, keyPath: ReferenceWritableKeyPath<AppearanceManager, String>) -> some View {
        HStack(spacing: 7) {
            ColorPicker(title, selection: colorBinding(for: keyPath), supportsOpacity: false)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
        }
    }

    private func colorBinding(for keyPath: ReferenceWritableKeyPath<AppearanceManager, String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: appearance[keyPath: keyPath]) ?? .systemRed) },
            set: { newColor in
                if let nsColor = NSColor(newColor).usingColorSpace(.sRGB) {
                    appearance[keyPath: keyPath] = nsColor.hexRGB
                }
            })
    }

    private func choiceRow<Value: CaseIterable & Identifiable & RawRepresentable>(
        _ title: String,
        values: Value.AllCases,
        selected: Value,
        onSelect: @escaping (Value) -> Void
    ) -> some View where Value.RawValue == String, Value: Equatable, Value.AllCases: RandomAccessCollection {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
                .frame(width: 58, alignment: .leading)
            ForEach(values) { value in
                DSChip(title: value.rawValue, selected: selected == value) { onSelect(value) }
            }
        }
    }

    private var depthShadowColor: Color {
        switch appearance.depth {
        case .flat: return .clear
        case .soft: return .black.opacity(0.18)
        case .layered: return Color.dsAccent.opacity(0.13)
        }
    }

    private var depthShadowRadius: CGFloat {
        switch appearance.depth {
        case .flat: return 0
        case .soft: return 7
        case .layered: return 13
        }
    }

    private var depthShadowY: CGFloat { appearance.depth == .layered ? 5 : 2 }
}

// Suite-level preferences that belong to no single tool.
private struct SuitePrefsFooter: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack(spacing: 10) {
            DSCheckbox(isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }))
            Text("Launch at login")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
            Spacer()
            Text("V0 \u{00B7} LOCAL ONLY")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .kerning(1.0)
                .foregroundStyle(Color.dsFaint)
        }
        .padding(.top, 4)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            // Registers the running bundle; only sticks for the /Applications
            // install, which is where build.sh puts every build.
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            Log.info("launch at login \(enabled ? "enabled" : "disabled")")
        } catch {
            Log.error("launch at login change failed: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct ModuleCard: View {
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject private var appearance = AppearanceManager.shared
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
                    // Rich tools open their own settings window; simple ones
                    // (Caps Lock) disclose the few controls right here.
                    switch registry.module(id: info.id)?.settingsStyle {
                    case .window:
                        Button {
                            registry.module(id: info.id)?.openSettings()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.dsMuted)
                                .frame(width: 26, height: 26)
                                .background(
                                    hovering ? Color(nsColor: DS.controlHover) : Color.clear,
                                    in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(info.displayName) settings")
                    case .inline:
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
                    default:
                        EmptyView()
                    }
                }
            }
            .padding(appearance.density.cardPadding + 2)

            if expanded, !comingSoon, let module = registry.module(id: info.id),
               module.settingsStyle == .inline {
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
        .shadow(color: cardShadowColor, radius: cardShadowRadius, y: cardShadowY)
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

    private var cardShadowColor: Color {
        switch appearance.depth {
        case .flat: return .clear
        case .soft: return .black.opacity(0.14)
        case .layered: return .black.opacity(0.3)
        }
    }

    private var cardShadowRadius: CGFloat {
        switch appearance.depth {
        case .flat: return 0
        case .soft: return 5
        case .layered: return 10
        }
    }

    private var cardShadowY: CGFloat { appearance.depth == .layered ? 4 : 1 }
}
