import AppKit
import SwiftUI
import FreeSpeechCore

final class HistoryViewModel: ObservableObject {
    @Published var query: String = "" { didSet { refresh() } }
    @Published var entries: [HistoryEntry] = []

    private let store: HistoryStore
    let onInsert: (String) -> Void

    init(store: HistoryStore, onInsert: @escaping (String) -> Void) {
        self.store = store
        self.onInsert = onInsert
        refresh()
    }

    func refresh() {
        entries = store.recent(matching: query)
    }

    func copy(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        Log.info("history: copied entry from \(entry.appName) (\(entry.text.count) chars)")
    }

    func clearAll() {
        Log.info("history cleared from window (\(entries.count) entries)")
        storeClear()
        refresh()
    }

    private func storeClear() {
        store.clear()
    }
}

// Local transcript history: searchable, copy or re-insert. Greenlight styling.
struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FREESPEECH")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .kerning(1.2)
                        .foregroundStyle(Color.dsAccent)
                    Text("History")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(Color.dsPaper)
                }
                Spacer()
                Button("Clear All") { model.clearAll() }
                    .buttonStyle(GhostButtonStyle())
                    .opacity(model.entries.isEmpty ? 0.5 : 1)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dsFaint)
                TextField("Search transcripts", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.dsPaper)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.dsInk2, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                    .strokeBorder(Color.dsLine, lineWidth: 1))

            if model.entries.isEmpty {
                VStack(spacing: 8) {
                    Text("EMPTY")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .kerning(1.2)
                        .foregroundStyle(Color.dsFaint)
                    Text(model.query.isEmpty ? "No dictations yet" : "No matches")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.dsMuted)
                    Text(model.query.isEmpty
                         ? "Hold your hotkey and speak - every insertion lands here."
                         : "Try a shorter search.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 48)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .background(Color.dsInk0)
        .onAppear { model.refresh() }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HistoryRow(entry: entry, model: model, timeFormatter: Self.timeFormatter)
    }
}

// Copy/Insert stay hidden until hover so the resting list is just transcripts.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let model: HistoryViewModel
    let timeFormatter: DateFormatter
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(timeFormatter.string(from: entry.timestamp).uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .kerning(1.0)
                    .foregroundStyle(Color.dsFaint)
                Text(entry.appName.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .kerning(1.0)
                    .foregroundStyle(Color.dsMuted)
                if entry.source == "systemAudio" {
                    Text("SYSTEM AUDIO")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .kerning(1.0)
                        .foregroundStyle(Color.dsAccent)
                }
                Spacer()
                HStack(spacing: 12) {
                    hoverButton("Copy") { model.copy(entry) }
                    hoverButton("Insert") { model.onInsert(entry.text) }
                }
                .opacity(hovering ? 1 : 0)
            }
            Text(entry.text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Color.dsPaper)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsInk1, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .strokeBorder(Color.dsLine, lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.durInstant), value: hovering)
    }

    private func hoverButton(_ title: String, action: @escaping () -> Void) -> some View {
        HistoryActionButton(title: title, action: action)
    }
}

private struct HistoryActionButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Color.dsAccent : Color.dsMuted)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.durInstant), value: hovering)
    }
}

final class HistoryWindowController {
    private var window: NSWindow?
    private var model: HistoryViewModel?
    private let makeModel: () -> HistoryViewModel

    init(makeModel: @escaping () -> HistoryViewModel) {
        self.makeModel = makeModel
    }

    func show() {
        if window == nil {
            let model = makeModel()
            self.model = model
            let hosting = NSHostingController(rootView: HistoryView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = DS.ink0
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        model?.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("history window opened")
    }

    func hide() {
        window?.orderOut(nil)
    }
}
