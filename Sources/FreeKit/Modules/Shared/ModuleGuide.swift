import SwiftUI
import FreeKitCore

// Per-tool first-run how-to. Speech has its own full onboarding window; every
// other tool shows a short guide the first time its settings open, then never
// again (tracked in UserDefaults, one flag per module id).

struct ModuleGuideStep {
    let icon: String
    let title: String
    let detail: String
}

struct ModuleGuide {
    let steps: [ModuleGuideStep]
}

enum ModuleGuides {
    static func guide(for id: String) -> ModuleGuide? { guides[id] }

    private static func seenKey(_ id: String) -> String { "guide.seen.\(id)" }
    static func hasSeen(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: seenKey(id)) }
    static func markSeen(_ id: String) { UserDefaults.standard.set(true, forKey: seenKey(id)) }

    private static let guides: [String: ModuleGuide] = [
        ModuleCatalog.clop.id: ModuleGuide(steps: [
            .init(icon: "doc.on.clipboard", title: "Compress on copy",
                  detail: "Copy an image, video, or PDF and Clop shrinks it in place; the toast shows what it saved."),
            .init(icon: "hand.draw", title: "Or drop to optimize",
                  detail: "Drag files onto the menu-bar icon, or the drop zone that appears while you drag."),
            .init(icon: "slider.horizontal.3", title: "Tune quality and rules",
                  detail: "Set format, max size, and a minimum-savings floor so small files are left untouched."),
        ]),
        ModuleCatalog.autoclicker.id: ModuleGuide(steps: [
            .init(icon: "cursorarrow.click.2", title: "Set your click",
                  detail: "Choose the interval, button, and whether to click at the cursor or a fixed point."),
            .init(icon: "keyboard", title: "Start and stop",
                  detail: "Trigger with the hotkey or the Start button; the same hotkey stops it, and moving the mouse stops a fixed-point run."),
            .init(icon: "square.stack.3d.up", title: "Record a macro",
                  detail: "The Macro tab captures a sequence of clicks and keystrokes to replay on demand."),
        ]),
        ModuleCatalog.appCleaner.id: ModuleGuide(steps: [
            .init(icon: "trash", title: "Remove apps cleanly",
                  detail: "Pick an app to see it plus every leftover support file it left behind."),
            .init(icon: "checklist", title: "Review, then trash",
                  detail: "Confirm what gets removed; everything goes to the Trash, nothing is deleted outright."),
        ]),
        ModuleCatalog.notebook.id: ModuleGuide(steps: [
            .init(icon: "note.text", title: "Summon anywhere",
                  detail: "Press the Notebook hotkey to float a note over whatever you are doing."),
            .init(icon: "magnifyingglass", title: "Search and style",
                  detail: "Notes save to disk automatically; search the sidebar and style text from the toolbar."),
        ]),
        ModuleCatalog.shelf.id: ModuleGuide(steps: [
            .init(icon: "tray.and.arrow.down", title: "Shake to park",
                  detail: "Give a drag a quick wiggle and the shelf appears; drop files onto it to hold them."),
            .init(icon: "hand.point.up.left", title: "Drag back out",
                  detail: "Pull any parked file off the shelf and drop it wherever you need it next."),
        ]),
        ModuleCatalog.stats.id: ModuleGuide(steps: [
            .init(icon: "gauge.with.dots.needle.50percent", title: "Live in the menu bar",
                  detail: "CPU, memory, network, and Bluetooth battery update live beside the clock."),
            .init(icon: "eye", title: "Pick what shows",
                  detail: "Choose which readouts appear and how often they refresh."),
        ]),
        ModuleCatalog.hyperKey.id: ModuleGuide(steps: [
            .init(icon: "capslock", title: "Your HyperKey",
                  detail: "Remap the Caps Lock key to a hyper key, Command, or tap-for-Escape; hold and tap can do different things."),
            .init(icon: "keyboard.badge.ellipsis", title: "Pick the modifiers",
                  detail: "Choose exactly which modifiers the hold sends, so it fits your shortcuts."),
        ]),
        ModuleCatalog.amphetamine.id: ModuleGuide(steps: [
            .init(icon: "pills", title: "Stay awake on demand",
                  detail: "Pick a timer from the menu bar icon, or right-click it to hold the Mac awake until you right-click again."),
            .init(icon: "laptopcomputer", title: "One thing it can't do",
                  detail: "Closing the lid with no external display always sleeps the Mac; that veto belongs to macOS, not apps."),
        ]),
        ModuleCatalog.boringNotch.id: ModuleGuide(steps: [
            .init(icon: "sparkles.rectangle.stack", title: "Beside the notch",
                  detail: "Media controls and your next calendar event live by the notch; hover to expand it."),
            .init(icon: "music.note", title: "Sources and widgets",
                  detail: "Choose Spotify or Apple Music and toggle the clock, battery, and calendar."),
        ]),
        ModuleCatalog.convert.id: ModuleGuide(steps: [
            .init(icon: "arrow.triangle.2.circlepath", title: "Pick your targets",
                  detail: "Choose the output format for images, audio, video, documents, and PDFs, once each."),
            .init(icon: "hand.draw", title: "Drop to convert",
                  detail: "Drag files onto the menu-bar icon; nothing converts until you explicitly ask it to."),
            .init(icon: "keyboard", title: "Clipboard and Finder",
                  detail: "Hotkeys convert whatever file is on the clipboard or selected in Finder, no drag required."),
        ]),
    ]
}

struct ModuleGuideOverlay: View {
    let info: ModuleInfo
    let guide: ModuleGuide
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: info.symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.dsAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HOW \(info.displayName.uppercased()) WORKS")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .kerning(1.2)
                        .foregroundStyle(Color.dsAccent)
                    Text("Quick start")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(Color.dsPaper)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: step.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.dsAccent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.dsPaper)
                            Text(step.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.dsMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Got it", action: onDismiss)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color.dsInk1, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
            .strokeBorder(Color.dsLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
    }
}

extension View {
    // Shows the module's how-to the first time its settings open, once per module.
    func moduleGuide(for info: ModuleInfo) -> some View {
        modifier(ModuleGuidePresenter(info: info))
    }
}

private struct ModuleGuidePresenter: ViewModifier {
    let info: ModuleInfo
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if showing, let guide = ModuleGuides.guide(for: info.id) {
                    ModuleGuideOverlay(info: info, guide: guide, onDismiss: dismiss)
                        .transition(.opacity)
                }
            }
            .onAppear {
                guard ModuleGuides.guide(for: info.id) != nil,
                      !ModuleGuides.hasSeen(info.id) else { return }
                withAnimation(DS.animBase) { showing = true }
            }
    }

    private func dismiss() {
        ModuleGuides.markSeen(info.id)
        withAnimation(DS.animBase) { showing = false }
    }
}
