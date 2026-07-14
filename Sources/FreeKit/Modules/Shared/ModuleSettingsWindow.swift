import AppKit
import SwiftUI
import FreeKitCore

// Shared building blocks every module's settings pane is built from. The
// panes themselves are hosted as a modal popup inside the Control Center
// window — see ControlCenterWindow.swift's ModuleSettingsCard.

// MARK: - Shared pane building blocks

// Card container: groups a settings topic under one kicker so panes read as
// sections instead of a wall of controls.
struct DSSettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ObservedObject private var appearance = AppearanceManager.shared

    var body: some View { card }

    private var card: some View {
        VStack(alignment: .leading, spacing: appearance.density.contentSpacing) {
            DSSectionLabel(title)
            content
        }
        .padding(appearance.density.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Color.dsInk1
                DSGrainOverlay(opacity: 0.1)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)))
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
        HStack(alignment: .center, spacing: 10) {
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
            DSToggle(isOn: $isOn)
        }
        .contentShape(Rectangle())
        .dsHoverHighlight(cornerRadius: DS.radiusKeycap)
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
            // Focus accent border fades in rather than snapping.
            .animation(DS.animInstant, value: focused)
            .onAppear { text = format(value) }
            .onChange(of: value) { _, newValue in
                if !focused { text = format(newValue) }
            }
            // Commit valid in-range values as they are typed (without
            // reformatting the text mid-edit): a run started by hotkey while
            // the field still has focus must use the number on screen, not the
            // last blurred value.
            .onChange(of: text) { _, newText in
                guard focused,
                      let parsed = Double(newText.replacingOccurrences(of: ",", with: ".")),
                      range.contains(parsed), parsed != value else { return }
                value = parsed
                onCommit(parsed)
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
