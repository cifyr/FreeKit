import AppKit
import SwiftUI
import FreeSpeechCore

// One Greenlight-styled settings window per module, hosting the module's
// settings pane. Speech keeps its original tabbed window; everything else
// gets this shell so settings live with the tool, not in the control center.
final class ModuleSettingsWindowController {
    private var window: NSWindow?
    private let info: ModuleInfo
    private let contentSize: NSSize
    private let minimumSize: NSSize
    private let makePane: () -> AnyView

    init(
        info: ModuleInfo,
        contentSize: NSSize = NSSize(width: 540, height: 620),
        minimumSize: NSSize = NSSize(width: 480, height: 360),
        makePane: @escaping () -> AnyView
    ) {
        self.info = info
        self.contentSize = contentSize
        self.minimumSize = minimumSize
        self.makePane = makePane
    }

    func show() {
        if window == nil {
            let root = ModuleSettingsContainer(info: info, pane: makePane())
            let hosting = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            w.title = "\(info.displayName) Settings"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = DS.ink0
            w.minSize = minimumSize
            w.setContentSize(contentSize)
            // Hidden titlebar leaves nothing to grab; drag anywhere instead.
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("settings window opened: \(info.id)")
    }
}

private struct ModuleSettingsContainer: View {
    let info: ModuleInfo
    let pane: AnyView
    @ObservedObject private var appearance = AppearanceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FREEKIT / \(info.displayName.uppercased())")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(Color.dsAccent)
                Text("Settings")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(Color.dsPaper)
            }
            ScrollView {
                pane
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 16)
            }
        }
        .padding(20)
        .frame(minWidth: 480, maxWidth: .infinity,
               minHeight: 360, maxHeight: .infinity)
        .background(AppearanceBackground())
    }
}

// MARK: - Shared pane building blocks

// Card container: groups a settings topic under one kicker so panes read as
// sections instead of a wall of controls.
struct DSSettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ObservedObject private var appearance = AppearanceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: appearance.density.contentSpacing) {
            DSSectionLabel(title)
            content
        }
        .padding(appearance.density.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.dsInk1,
            in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .strokeBorder(Color.dsLine, lineWidth: 1))
        .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
    }

    private var shadowColor: Color {
        switch appearance.depth {
        case .flat: return .clear
        case .soft: return .black.opacity(0.14)
        case .layered: return .black.opacity(0.3)
        }
    }

    private var shadowRadius: CGFloat {
        switch appearance.depth {
        case .flat: return 0
        case .soft: return 5
        case .layered: return 10
        }
    }

    private var shadowY: CGFloat { appearance.depth == .layered ? 4 : 1 }
}

struct DSSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .kerning(1.2)
            .foregroundStyle(Color.dsMuted)
    }
}

// Checkbox row with title + optional caption, the settings-pane workhorse.
struct DSToggleRow: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            DSCheckbox(isOn: $isOn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsPaper)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

// Numeric entry in the DS control chrome; commits on Enter or focus loss and
// snaps back into range so a typo can never produce a runaway value.
struct DSNumberField: View {
    let placeholder: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var fractionDigits: Int = 2
    var onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Color.dsPaper)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(width: 88, height: 30)
            .background(
                Color.dsInk2,
                in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous)
                    .strokeBorder(focused ? Color.dsAccent.opacity(0.6) : Color.dsLine, lineWidth: 1))
            .onAppear { text = format(value) }
            .onChange(of: value) { _, newValue in
                if !focused { text = format(newValue) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit { commit() }
    }

    private func commit() {
        let parsed = Double(text.replacingOccurrences(of: ",", with: ".")) ?? value
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        text = format(clamped)
        guard clamped != value else { return }
        value = clamped
        onCommit(clamped)
    }

    private func format(_ v: Double) -> String {
        v.rounded() == v && fractionDigits > 0
            ? String(format: "%.0f", v)
            : String(format: "%.\(fractionDigits)f", v)
    }
}
