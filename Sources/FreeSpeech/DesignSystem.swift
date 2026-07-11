import AppKit
import SwiftUI

// Port of the ETok "Greenlight" design system (DESIGN.md), red variant:
// same ink neutrals, hairlines, radii, and mono label voice, with the volt-lime
// accent swapped for Apple's dark-mode system red so it reads native on macOS.
enum DS {
    static let ink0 = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 1)   // 0A0A0C
    static let ink1 = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.094, alpha: 1)   // 131318
    static let ink2 = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.141, alpha: 1)   // 1D1D24
    static let ink3 = NSColor(srgbRed: 0.149, green: 0.149, blue: 0.184, alpha: 1)   // 26262F
    static let line = NSColor(srgbRed: 0.165, green: 0.165, blue: 0.200, alpha: 1)   // 2A2A33
    static let paper = NSColor(srgbRed: 0.961, green: 0.961, blue: 0.941, alpha: 1)  // F5F5F0
    static let muted = NSColor(srgbRed: 0.557, green: 0.557, blue: 0.600, alpha: 1)  // 8E8E99
    static let faint = NSColor(srgbRed: 0.333, green: 0.333, blue: 0.373, alpha: 1)  // 55555F
    static var accent: NSColor { AppearanceManager.shared.accentColor }
    static var accentDim: NSColor { AppearanceManager.shared.accentDimColor }
    static let glass = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.094, alpha: 0.85)
    // Hover overlay for transparent controls; ink3 is the hover/selected fill.
    static let controlHover = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05)

    static var radiusControl: CGFloat { AppearanceManager.shared.corners.controlRadius }
    static var radiusCard: CGFloat { AppearanceManager.shared.corners.cardRadius }
    static let radiusSheet: CGFloat = 28
    static let radiusKeycap: CGFloat = 10

    // One decelerate curve for all interface motion keeps the app calm;
    // only the pulse breathes symmetrically (ease-in-out, in HUD).
    static let durInstant: TimeInterval = 0.12
    static let durBase: TimeInterval = 0.20
    static let durSlow: TimeInterval = 0.32
    static let hudCrossfade: TimeInterval = 0.18

    // Greenlight's mono label voice: micro size, uppercase, wide tracking.
    static func microLabel(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .kern: 1.2,
                .foregroundColor: muted,
            ])
    }
}

// Greenlight ghost button: transparent fill, hairline border, paper text;
// hover lifts with the controlHover overlay, press fills ink3.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration)
    }

    private struct GhostButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(
                    configuration.isPressed
                        ? Color.dsInk3
                        : (hovering ? Color(nsColor: DS.controlHover) : Color.clear),
                    in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                        .strokeBorder(Color.dsLine, lineWidth: 1))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: DS.durInstant), value: configuration.isPressed)
                .animation(.easeOut(duration: DS.durInstant), value: hovering)
        }
    }
}

// Filled default-action button: paper fill, ink text. One per screen; accent
// red is the app's live-voice color, never decoration.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.dsInk0)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(
                Color.dsPaper.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .animation(.easeOut(duration: DS.durInstant), value: configuration.isPressed)
    }
}

// Minimal boolean toggle: 18x18, dark in both states, the paper check is the
// only bright mark. Quieter than a switch; accent stays reserved for live voice.
struct DSCheckbox: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? Color.dsInk3 : (hovering ? Color.dsInk3 : Color.dsInk2))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.dsLine, lineWidth: 1)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.dsPaper)
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.durInstant), value: isOn)
    }
}

// Capsule chip for short one-of-many choices; hover fills ink3 at durInstant,
// selection is the accent-60 border + accent text.
struct DSChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.dsAccent : Color.dsPaper)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(hovering && !selected ? Color.dsInk3 : Color.dsInk2, in: Capsule())
                .overlay(Capsule().strokeBorder(
                    selected ? Color.dsAccent.opacity(0.6) : Color.dsLine, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.durInstant), value: hovering)
        .animation(.easeOut(duration: DS.durInstant), value: selected)
    }
}

// Quiet underline tab on a full-width hairline: selected = paper + 2px accent
// underline, unselected = muted lifting to paper on hover. No pill fill.
struct DSTabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.dsPaper : (hovering ? Color.dsPaper : Color.dsMuted))
                Rectangle()
                    .fill(selected ? Color.dsAccent : Color.clear)
                    .frame(height: 2)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.durBase), value: selected)
        .animation(.easeOut(duration: DS.durInstant), value: hovering)
    }
}

extension Color {
    static let dsInk0 = Color(nsColor: DS.ink0)
    static let dsInk1 = Color(nsColor: DS.ink1)
    static let dsInk2 = Color(nsColor: DS.ink2)
    static let dsInk3 = Color(nsColor: DS.ink3)
    static let dsLine = Color(nsColor: DS.line)
    static let dsPaper = Color(nsColor: DS.paper)
    static let dsMuted = Color(nsColor: DS.muted)
    static let dsFaint = Color(nsColor: DS.faint)
    static var dsAccent: Color { Color(nsColor: DS.accent) }
    static var dsAccentDim: Color { Color(nsColor: DS.accentDim) }
}
