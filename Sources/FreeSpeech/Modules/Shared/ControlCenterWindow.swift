import AppKit
import Combine
import ServiceManagement
import SwiftUI
import FreeSpeechCore

// Bridges "open this module's settings" (Control Center's own gear/Open
// button, a module's status-bar menu, or its own floating panel) into one
// place: the modal popup lives inside the Control Center window, so
// presenting it means bringing that window forward first.
final class ControlCenterPresenter: ObservableObject {
    static let shared = ControlCenterPresenter()
    @Published private(set) var presentedModuleID: String?
    // One-shot request for the hub to land on a specific tab (the notch gear
    // opens Tools); consumed and cleared by ControlCenterView.
    @Published var requestedSection: ControlCenterSection?
    fileprivate var showControlCenter: (() -> Void)?

    private init() {}

    func present(moduleID: String) {
        showControlCenter?()
        presentedModuleID = moduleID
    }

    func present(section: ControlCenterSection) {
        showControlCenter?()
        requestedSection = section
    }

    func dismiss() {
        presentedModuleID = nil
    }
}

enum ControlCenterSection: String, CaseIterable {
    case apps = "Apps"
    case tools = "Tools"
    case appearance = "Appearance"
    case roadmap = "Roadmap"
}

final class ControlCenterWindowController {
    private var window: NSWindow?
    private let registry: ModuleRegistry
    private var presenterCancellable: AnyCancellable?
    // The frame to restore once the popup closes; nil while no popup is open.
    private var preSettingsFrame: NSRect?

    init(registry: ModuleRegistry) {
        self.registry = registry
        ControlCenterPresenter.shared.showControlCenter = { [weak self] in self?.show() }
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
            // Dragging is explicit: the (invisible) titlebar strip plus the
            // WindowDragGesture on AppearanceBackground. Background-drag is off
            // because AppKit's version fought slider/control gestures.
            w.isMovableByWindowBackground = false
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            presenterCancellable = ControlCenterPresenter.shared.$presentedModuleID
                .removeDuplicates()
                .sink { [weak self] id in self?.resizeForPresentedModule(id) }
        }
        if let window { DSMotionAppKit.presentWindow(window) }
        NSApp.activate(ignoringOtherApps: true)
        Log.info("control center opened")
    }

    // Snaps the window to the popup's own size — shrinking as well as growing,
    // so a short modal isn't stranded in a tall hub — and restores the exact
    // pre-popup frame once it closes.
    private func resizeForPresentedModule(_ id: String?) {
        guard let window else { return }
        if let id, let module = registry.module(id: id) {
            if preSettingsFrame == nil { preSettingsFrame = window.frame }
            let ideal = module.settingsPopupSize
            let screen = window.screen?.visibleFrame.size
                ?? NSSize(width: CGFloat.greatestFiniteMagnitude,
                          height: CGFloat.greatestFiniteMagnitude)
            // Popup card floats with a 32pt gutter on every side (see
            // ModuleSettingsCard) so the host window needs that much extra room.
            let target = NSSize(
                width: min(max(ideal.width + 64, window.minSize.width), screen.width),
                height: min(max(ideal.height + 64, window.minSize.height), screen.height))
            // Matched to the card's expand spring so frame and content settle
            // together; the close path keeps the quicker default since the
            // popup is already fading out over it.
            DSMotionAppKit.resizeWindowMatchingExpand(window, toContentSize: target)
        } else if let restore = preSettingsFrame {
            DSMotionAppKit.resizeWindow(window, toFrame: restore)
            preSettingsFrame = nil
        }
    }
}

// One card per module: enable toggle, menu-bar toggle, disclosure into the
// module's inline settings pane. Coming-soon tools render greyed with a badge.
struct ControlCenterView: View {
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject private var appearance = AppearanceManager.shared
    @ObservedObject private var presenter = ControlCenterPresenter.shared
    @State private var expandedID: String?
    @State private var selectedSection: ControlCenterSection = .apps

    private static let appIDs = Set(ModuleCatalog.apps.map(\.id))
    // Convert is cross-listed: it lives in Apps (its real home) but also gets
    // a normal Tools card as a shortcut, since some of its controls (hotkeys,
    // drop zone, Finder integration) read as Tools-tab settings.
    private static let toolsProxyIDs: Set<String> = [ModuleCatalog.convert.id]

    private var visibleModules: [ModuleInfo] {
        registry.modules.map(\.info).filter { info in
            switch selectedSection {
            case .apps:
                return info.status == .available && Self.appIDs.contains(info.id)
            case .tools:
                return info.status == .available
                    && (!Self.appIDs.contains(info.id) || Self.toolsProxyIDs.contains(info.id))
            case .roadmap:
                return info.status == .comingSoon
            case .appearance:
                return false
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            mainContent
            if let id = presenter.presentedModuleID, let module = registry.module(id: id) {
                settingsPopup(for: module)
            }
        }
        .animation(DS.animExpand(), value: presenter.presentedModuleID)
        .onReceive(presenter.$requestedSection) { section in
            guard let section else { return }
            withAnimation(DS.animCrossfade) {
                selectedSection = section
                expandedID = nil
            }
            presenter.requestedSection = nil
        }
    }

    @ViewBuilder
    private func settingsPopup(for module: AppModule) -> some View {
        Color(nsColor: DS.glass)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { presenter.dismiss() }
            .transition(.opacity)
        ModuleSettingsCard(module: module)
            .padding(32)
            .transition(.dsAppear)
        // Sits exactly on the card's corner blob (see CornerBlobCardShape):
        // the button is a bulge of the sheet, not a separate floating circle.
        Button {
            presenter.dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.dsPress)
        .help("Back")
        .offset(x: 16, y: 16)
        .transition(.opacity)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FREEKIT")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(Color.dsAccent)
                Text("Control Center")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(Color.dsPaper)
                Text("One process, many small tools. Enable what you use.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dsMuted)
                HStack(spacing: 22) {
                    ForEach(ControlCenterSection.allCases, id: \.self) { section in
                        DSTabButton(
                            title: section.rawValue,
                            selected: selectedSection == section
                        ) {
                            withAnimation(DS.animCrossfade) {
                                selectedSection = section
                                expandedID = nil
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.bottom, 11)
                .overlay(alignment: .bottom) {
                    // Fade-edged baseline instead of a hard rule, matching
                    // the reference's "baseline is a fade, not a line".
                    LinearGradient(
                        colors: [Color.dsPaper.opacity(0.11), Color.dsPaper.opacity(0.11), .clear],
                        startPoint: .leading, endPoint: .trailing)
                        .frame(height: 1)
                }
            }
            if selectedSection == .appearance {
                AppearancePane()
                    .transition(.dsCrossfade)
            } else {
                ScrollView {
                    LazyVStack(spacing: appearance.density.contentSpacing) {
                        ForEach(Array(visibleModules.enumerated()), id: \.element.id) { index, info in
                            ModuleCard(
                                registry: registry,
                                info: info,
                                index: index,
                                expanded: expandedID == info.id,
                                showsOpenButton: selectedSection == .apps,
                                onToggleExpanded: {
                                    withAnimation(DS.animBase) {
                                        expandedID = expandedID == info.id ? nil : info.id
                                    }
                                })
                        }
                    }
                    .padding(.bottom, 12)
                }
                .dsScrollEdgeFade()
                .transition(.dsCrossfade)
            }
            SuitePrefsFooter()
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 600, maxWidth: .infinity,
               minHeight: 480, idealHeight: 720, maxHeight: .infinity)
        .background(AppearanceBackground())
    }
}

// A module's settings, floated as a modal card inside the Control Center
// window instead of a separate NSWindow. Speech's own tabbed view already
// renders a title/scroll of its own (popupUsesOwnChrome), so it's hosted edge
// to edge; every other module gets the shared kicker + "Settings" header.
private struct ModuleSettingsCard: View {
    let module: AppModule
    @ObservedObject private var appearance = AppearanceManager.shared

    var body: some View {
        Group {
            if module.popupUsesOwnChrome {
                module.makeSettingsPane()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FREEKIT / \(module.info.displayName.uppercased())")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .kerning(1.2)
                            .foregroundStyle(Color.dsAccent)
                        Text("Settings")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(Color.dsPaper)
                    }
                    ScrollView {
                        module.makeSettingsPane()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 16)
                    }
                    .dsScrollEdgeFade()
                }
                .padding(20)
                // First time this tool's settings open, show its short how-to.
                .moduleGuide(for: module.info)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Content clips to the plain sheet; the fill and the single border
        // trace the sheet-plus-blob union so the back button's circle reads
        // as part of the card. Circular corners here, matching the hand-drawn
        // blob outline's arcs, so clipped content never overhangs the border.
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSheet, style: .circular))
        // Filling the blob Shape directly (not a View clipped to it) matters
        // here: the blob deliberately overflows its nominal frame to bulge
        // out for the back button, and a clipped View can't reveal anything
        // beyond its own laid-out bounds — the bulge rendered empty/see-
        // through until this switched to Shape.fill(), which draws the full
        // path (including the overflow) as one continuous surface.
        .background(
            ZStack {
                // dsInk0, not dsInk1: the same wash opacity reads noticeably
                // more saturated against the lighter ink1 base than it does
                // on the main window's dsInk0 background — matching the base
                // color is what makes this card's wash read as subdued the
                // same way the app background's does, at the same intensity.
                Self.blobShape.fill(Color.dsInk0)
                Self.blobShape.fill(appearance.washPrimary)
                Self.blobShape.fill(appearance.washSecondary)
                // Same reasoning as the gradient above: ImagePaint as a
                // Shape.fill() style tiles correctly across the full path,
                // overflow included, where a clipped grain View would not.
                Self.blobShape
                    .fill(ImagePaint(image: Image(nsImage: DSGrainOverlay.tile), sourceRect: Self.grainSourceRect))
                    .blendMode(.overlay)
                    .opacity(0.16)
            })
        .overlay(Self.blobShape.stroke(Color.dsLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 26, y: 12)
    }

    private static var blobShape: CornerBlobCardShape {
        CornerBlobCardShape(
            cornerRadius: DS.radiusSheet, blobRadius: 18, blobInset: 2, filletRadius: 10)
    }

    // ImagePaint's sourceRect is a fraction of the unit square, not a pixel
    // size, so it can't be computed from the tile's native 128px size alone —
    // this approximates a ~128pt tile at a typical ~560pt popup width so the
    // grain reads at roughly the same density as everywhere else it's used.
    private static let grainSourceRect = CGRect(x: 0, y: 0, width: 0.46, height: 0.46)
}

// The settings sheet with the back button's circle coalescing out of its
// top-left corner, metaball-style: the outline runs around the card, curves
// concavely through a tangent fillet into the circle's outer bulge, and back
// through a matching fillet onto the top edge — one continuous silhouette
// with smooth necks, never a circle merely overlapping a rectangle.
private struct CornerBlobCardShape: Shape {
    let cornerRadius: CGFloat
    let blobRadius: CGFloat
    // How far the circle's center sits inside the corner; deeper = wider neck.
    let blobInset: CGFloat
    // Radius of the concave neck arcs joining the blob to the card edges.
    let filletRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = cornerRadius
        let r = blobRadius
        let f = filletRadius
        let origin = CGPoint(x: rect.minX, y: rect.minY)
        let c = CGPoint(x: origin.x + blobInset, y: origin.y + blobInset)
        // Fillet circles sit just outside the top and left edges, externally
        // tangent to the blob; solving the tangency triangle places them.
        let k = r + f
        let m = f + blobInset
        let reach = (k * k - m * m).squareRoot()
        let filletTop = CGPoint(x: c.x + reach, y: origin.y - f)
        let filletLeft = CGPoint(x: origin.x - f, y: c.y + reach)
        let blobMeetsTop = CGPoint(x: c.x + r * reach / k, y: c.y - r * m / k)
        let blobMeetsLeft = CGPoint(x: c.x - r * m / k, y: c.y + r * reach / k)

        func angle(from center: CGPoint, to point: CGPoint) -> Angle {
            .radians(Double(atan2(point.y - center.y, point.x - center.x)))
        }

        var p = Path()
        p.move(to: CGPoint(x: filletTop.x, y: origin.y))
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                 radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0),
                 clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                 radius: radius, startAngle: .degrees(0), endAngle: .degrees(90),
                 clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                 radius: radius, startAngle: .degrees(90), endAngle: .degrees(180),
                 clockwise: false)
        p.addLine(to: CGPoint(x: origin.x, y: filletLeft.y))
        // Concave neck curving off the left edge into the blob...
        p.addArc(center: filletLeft, radius: f,
                 startAngle: .degrees(0),
                 endAngle: angle(from: filletLeft, to: blobMeetsLeft),
                 clockwise: true)
        // ...around the blob's outer bulge...
        p.addArc(center: c, radius: r,
                 startAngle: angle(from: c, to: blobMeetsLeft),
                 endAngle: angle(from: c, to: blobMeetsTop),
                 clockwise: false)
        // ...and concavely back down onto the top edge.
        p.addArc(center: filletTop, radius: f,
                 startAngle: angle(from: filletTop, to: blobMeetsTop),
                 endAngle: .degrees(90),
                 clockwise: true)
        p.closeSubpath()
        return p
    }
}

private struct AppearancePane: View {
    @ObservedObject private var appearance = AppearanceManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: appearance.density.contentSpacing) {
                preview

                DSSettingsCard(title: "Wash") {
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
                        DSSlider(value: $appearance.gradientIntensity, range: 0.1...0.85)
                        Text("\(Int(appearance.gradientIntensity * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.dsMuted)
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                DSSettingsCard(title: "Layout") {
                    choiceRow("Density", values: AppearanceDensity.allCases,
                              selected: appearance.density) { appearance.density = $0 }
                }

            }
            .padding(.bottom, 12)
        }
        .dsScrollEdgeFade()
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
                Text("Duotone Wash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dsPaper)
                Text("FreeKit's signature look: warm-to-cool grain wash, red reserved for live and for what's on.")
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
            SuiteUpdateButton()
        }
        .padding(.top, 14)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.clear, Color.dsPaper.opacity(0.1), Color.dsPaper.opacity(0.1), .clear],
                startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
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

// Reusable Update control: rebuild from source and relaunch. Drop into any
// window's footer so a code change lands without leaving the app.
struct SuiteUpdateButton: View {
    @StateObject private var updater = SuiteUpdater()

    var body: some View {
        Button(action: updater.update) {
            HStack(spacing: 6) {
                if updater.state == .updating {
                    ProgressView().controlSize(.small).tint(Color.dsAccent)
                } else {
                    Image(systemName: updater.state == .failed
                          ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(updater.state == .updating ? "Updating\u{2026}"
                     : (updater.state == .failed ? "Retry Update" : "Update"))
            }
        }
        .buttonStyle(GhostButtonStyle())
        .disabled(updater.state == .updating)
        .help("Rebuild FreeKit from source and relaunch")
    }
}

// Rebuilds the working copy via build.sh and relaunches the freshly installed
// bundle. A personal-tool affordance, so the repo path is fixed to this
// machine's checkout; if it is missing the button simply reports failure.
final class SuiteUpdater: ObservableObject {
    enum State { case idle, updating, failed }
    @Published var state: State = .idle

    private let repo = "/Users/caden/ClaudeCode/idk/FreeSpeech"
    private let installed = "/Applications/FreeKit.app"

    func update() {
        guard state != .updating else { return }
        guard FileManager.default.fileExists(atPath: repo + "/build.sh") else {
            Log.error("update: build.sh not found at \(repo)")
            state = .failed
            return
        }
        state = .updating
        Log.info("update: rebuilding from \(repo)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Login shell so the Swift/cmake toolchain resolves on PATH the same
            // way a terminal build does.
            task.arguments = ["-lc", "cd \(self.repo) && ./build.sh --skip-model"]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                Log.error("update: could not launch build: \(error.localizedDescription)")
                DispatchQueue.main.async { self.state = .failed }
                return
            }
            let ok = task.terminationStatus == 0
            Log.info("update: build exited \(task.terminationStatus)")
            DispatchQueue.main.async { ok ? self.relaunch() : (self.state = .failed) }
        }
    }

    private func relaunch() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", installed]
        try? open.run()
        // Let the fresh instance come up before this one exits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}

private struct ModuleCard: View {
    @ObservedObject var registry: ModuleRegistry
    @ObservedObject private var appearance = AppearanceManager.shared
    let info: ModuleInfo
    var index: Int = 0
    let expanded: Bool
    var showsOpenButton = false
    let onToggleExpanded: () -> Void
    @State private var hovering = false
    @State private var appeared = false

    private var comingSoon: Bool { info.status == .comingSoon }
    private var enabled: Bool { registry.isEnabled(id: info.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: info.symbolName)
                    .font(.system(size: 16, weight: .medium))
                    // A few symbols (Amphetamine's "pills" among them) default
                    // to a multicolor palette that ignores foregroundStyle
                    // unless rendering mode is pinned to monochrome — without
                    // this it can render with a near-black half regardless of
                    // the tint below.
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(
                        comingSoon ? Color.dsFaint : (enabled ? Color.dsAccent : Color.dsMuted))
                    .animation(DS.animBase, value: enabled)
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
                    // App cards have no enabled concept in the UI: Open is the
                    // whole lifecycle.
                    if !showsOpenButton {
                        toggleColumn(
                            label: "ON",
                            isOn: Binding(
                                get: { registry.isEnabled(id: info.id) },
                                set: { registry.setEnabled($0, id: info.id) }))
                        if info.ownsMenuBarItem {
                            menuBarToggleColumn(
                                isOn: Binding(
                                    get: { registry.showsMenuBarItem(id: info.id) },
                                    set: { registry.setShowsMenuBarItem($0, id: info.id) }))
                                // Stays live while the tool is off so the choice can be
                                // pre-set; dimmed because it changes nothing until then.
                                .opacity(enabled ? 1 : 0.4)
                                .animation(DS.animBase, value: enabled)
                                .help("Show \(info.displayName) in the menu bar")
                        }
                    }
                    if showsOpenButton {
                        // One click: enabling on demand means Open always works.
                        Button("Open") {
                            if !enabled { registry.setEnabled(true, id: info.id) }
                            registry.module(id: info.id)?.openSettings()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Open \(info.displayName)")
                    }
                    // Rich tools open a settings popup; simple ones (Caps
                    // Lock) disclose the few controls right here. App cards
                    // skip the gear — Open reaches the same popup.
                    switch registry.module(id: info.id)?.settingsStyle {
                    case .popup where !showsOpenButton:
                        Button {
                            // Convert's Tools-tab card is a proxy into its Apps-tab
                            // home; opening it from here reads as configuring the
                            // tool, so it should land on the Tool tab, not App.
                            if info.id == ModuleCatalog.convert.id,
                               let convert = registry.module(id: info.id) as? ConvertModule {
                                convert.openSettingsOnToolTab()
                            } else {
                                registry.module(id: info.id)?.openSettings()
                            }
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.dsMuted)
                                .frame(width: 26, height: 26)
                                .background(
                                    hovering ? Color(nsColor: DS.controlHover) : Color.clear,
                                    in: Circle())
                        }
                        .buttonStyle(.dsPress)
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
                        .buttonStyle(.dsPress)
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
            ZStack {
                Color.white.opacity(0.032)
                DSGrainOverlay(opacity: 0.09)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)))
        .overlay(
            // Brighter at the top edge, approximating the reference's inset
            // top highlight (a raised-card cue) without a custom shape.
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.08), Color.dsLine],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
        .opacity(comingSoon ? 0.55 : 1)
        .shadow(color: cardShadowColor, radius: cardShadowRadius, y: cardShadowY)
        .onHover { hovering = $0 }
        .animation(DS.animInstant, value: hovering)
        // Quiet staggered entrance so the grid settles in on open, not all at once.
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 5)
        .onAppear { withAnimation(DS.animAppear(index: index)) { appeared = true } }
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

    // Deliberately a different affordance from the ON checkbox: a menu-bar
    // glyph that tints accent when visible, so "on" vs. "shown in the menu
    // bar" read as two distinct states at a glance instead of two identical
    // checkmarks.
    private func menuBarToggleColumn(isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            VStack(spacing: 5) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn.wrappedValue ? Color.dsAccent : Color.dsMuted)
                    .frame(width: 18, height: 18)
                    .background(
                        isOn.wrappedValue ? Color.dsAccent.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(isOn.wrappedValue ? Color.dsAccent.opacity(0.4) : Color.dsLine, lineWidth: 1))
                Text("MENU")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(Color.dsFaint)
            }
            .frame(minWidth: 44)
        }
        .buttonStyle(.dsPress)
        .animation(DS.animInstant, value: isOn.wrappedValue)
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
