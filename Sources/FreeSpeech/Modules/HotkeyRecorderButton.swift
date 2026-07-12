import SwiftUI
import FreeSpeechCore

// Shared shortcut recorder for module settings panes. Escape clears the
// binding; clicking elsewhere leaves its current value unchanged.
struct HotkeyRecorderButton: View {
    let label: String
    @State var preset: HotkeyPreset
    let onChange: (HotkeyPreset) -> Void

    @State private var capturing = false
    @State private var capture = ShortcutCapture()

    var body: some View {
        HStack(spacing: 12) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(Color.dsMuted)
            Button {
                if capturing {
                    capture.end()
                    capturing = false
                } else {
                    capturing = true
                    capture.begin(
                        onSet: { newPreset in
                            capturing = false
                            preset = newPreset
                            onChange(newPreset)
                        },
                        onClear: {
                            capturing = false
                            preset = .disabled
                            onChange(.disabled)
                        },
                        onCancel: { capturing = false })
                }
            } label: {
                Text(capturing ? "Press keys\u{2026}" : preset.displayName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(capturing ? Color.dsAccent : Color.dsPaper)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(
                        Color.dsInk2,
                        in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                            .strokeBorder(
                                capturing ? Color.dsAccent.opacity(0.6) : Color.dsLine,
                                lineWidth: 1))
                    // Accent + "Press keys…" swap fade in rather than cut on toggle.
                    .dsContentCrossfade(capturing)
                    // While recording, the keycap breathes so "listening for keys" reads as alive; settles instantly when done.
                    .dsLivePulse(capturing, dimTo: 0.6)
            }
            .buttonStyle(.dsPress)
        }
        .onDisappear { if capturing { capture.end(); capturing = false } }
    }
}
