import AppKit
import SwiftUI
import FreeSpeechCore

extension AudioInputDevice: Identifiable {
    public var id: String { uid }
}

final class SettingsStore: ObservableObject {
    // SwiftUI also declares a `Settings` scene type, hence the qualified name.
    private let settings: FreeSpeechCore.Settings
    private let learningStore: LearningStore
    private let onHotkeyChanged: () -> Void
    private let onModelChanged: () -> Void
    private var captureMonitor: Any?
    private var involvedModifiers: Set<Int64> = []

    @Published var mode: ActivationMode { didSet { settings.mode = mode } }
    @Published var hotkey: HotkeyPreset {
        didSet {
            settings.hotkey = hotkey
            onHotkeyChanged()
        }
    }
    @Published var modelName: String {
        didSet {
            settings.modelName = modelName
            onModelChanged()
        }
    }
    @Published var postProcessing: PostProcessingMode { didSet { settings.postProcessing = postProcessing } }
    @Published var tone: RewriteTone { didSet { settings.tone = tone } }
    @Published var vocabularyHint: String { didSet { settings.vocabularyHint = vocabularyHint } }
    @Published var isCapturingShortcut = false
    @Published var installedModels: [String] = []
    @Published var connectedMics: [AudioInputDevice] = []
    @Published var micPriority: [String] { didSet { settings.micPriority = micPriority } }
    @Published var learningEnabled: Bool { didSet { settings.learningEnabled = learningEnabled } }
    @Published var learnedSummary: String = ""

    let languageModelAvailable: Bool

    init(settings: FreeSpeechCore.Settings, languageModelAvailable: Bool,
         learningStore: LearningStore,
         onHotkeyChanged: @escaping () -> Void, onModelChanged: @escaping () -> Void) {
        self.settings = settings
        self.learningStore = learningStore
        self.languageModelAvailable = languageModelAvailable
        self.onHotkeyChanged = onHotkeyChanged
        self.onModelChanged = onModelChanged
        _mode = Published(initialValue: settings.mode)
        _hotkey = Published(initialValue: settings.hotkey)
        _modelName = Published(initialValue: settings.modelName)
        _postProcessing = Published(initialValue: settings.postProcessing)
        _tone = Published(initialValue: settings.tone)
        _vocabularyHint = Published(initialValue: settings.vocabularyHint)
        _micPriority = Published(initialValue: settings.micPriority)
        _learningEnabled = Published(initialValue: settings.learningEnabled)
        refresh()
    }

    func refresh() {
        installedModels = AppPaths.installedModels()
        // Priority devices first (in priority order), then the rest as connected.
        let connected = AudioDevices.inputDevices()
        let prioritized = micPriority.compactMap { uid in connected.first { $0.uid == uid } }
        connectedMics = prioritized + connected.filter { d in !micPriority.contains(d.uid) }
        refreshLearnedSummary()
    }

    // nil = system default input (no priority set or none of them connected).
    var activeMicUID: String? {
        MicPriority.pick(priority: micPriority, connected: connectedMics.map(\.uid))
    }

    func promoteMic(_ uid: String) {
        micPriority = [uid] + micPriority.filter { $0 != uid }
        refresh()
    }

    func resetMicPriority() {
        micPriority = []
        refresh()
    }

    func resetLearning() {
        learningStore.reset()
        Log.info("learning store reset from settings")
        refreshLearnedSummary()
    }

    private func refreshLearnedSummary() {
        learnedSummary = "\(learningStore.promotedCount) active rules, \(learningStore.ruleCount) corrections observed"
    }

    // Captures the next chord as the hotkey: a plain key, a combo like Cmd+K or
    // Cmd+Opt+Space, or a bare modifier (press and release it alone). Esc cancels.
    func beginShortcutCapture() {
        guard captureMonitor == nil else { return }
        isCapturingShortcut = true
        involvedModifiers = []
        Log.info("shortcut capture started")
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let code = Int64(event.keyCode)
            switch event.type {
            case .keyDown:
                if code == 53 {  // Esc cancels without saving
                    self.endShortcutCapture()
                    return nil
                }
                // fn is excluded from combos: it rides along on F-keys and arrows.
                let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
                var mods: HotkeyModifiers = []
                if flags.contains(.command) { mods.insert(.command) }
                if flags.contains(.option) { mods.insert(.option) }
                if flags.contains(.shift) { mods.insert(.shift) }
                if flags.contains(.control) { mods.insert(.control) }
                self.capture(code, modifiers: mods)
                return nil
            case .flagsChanged:
                guard KeyNames.isModifier(code) else { return event }
                let anyHeld = !event.modifierFlags
                    .intersection([.command, .option, .shift, .control, .function]).isEmpty
                if anyHeld {
                    self.involvedModifiers.insert(code)
                } else {
                    // Everything released without a regular key: a single involved
                    // modifier means the user chose that modifier as the hotkey.
                    if self.involvedModifiers.count == 1, let only = self.involvedModifiers.first {
                        self.capture(only, modifiers: [])
                    }
                    self.involvedModifiers = []
                }
                return event
            default:
                return event
            }
        }
    }

    func endShortcutCapture() {
        if let captureMonitor {
            NSEvent.removeMonitor(captureMonitor)
        }
        captureMonitor = nil
        isCapturingShortcut = false
        involvedModifiers = []
    }

    private func capture(_ keyCode: Int64, modifiers: HotkeyModifiers) {
        endShortcutCapture()
        let preset = HotkeyPreset.custom(keyCode: keyCode, modifiers: modifiers)
        Log.info("shortcut captured: \(preset.displayName) [keyCode \(keyCode), modifiers \(modifiers.rawValue)]")
        hotkey = preset
    }
}

// Greenlight-styled settings: ink surfaces, hairlines, mono micro labels, red accent.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                card {
                    sectionLabel("Activation")
                    HStack(spacing: 8) {
                        ForEach(ActivationMode.allCases, id: \.self) { mode in
                            chip(mode.displayName, selected: store.mode == mode) {
                                store.mode = mode
                            }
                        }
                    }
                    Divider().overlay(Color.dsLine).padding(.vertical, 4)
                    sectionLabel("Hotkey")
                    HStack(spacing: 10) {
                        Text(store.isCapturingShortcut ? "PRESS A KEY\u{2026}" : store.hotkey.displayName.uppercased())
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .kerning(0.8)
                            .foregroundStyle(store.isCapturingShortcut ? Color.dsAccent : Color.dsPaper)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Color.dsInk2, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                                    .strokeBorder(store.isCapturingShortcut ? Color.dsAccent : Color.dsLine, lineWidth: 1))
                        Button(store.isCapturingShortcut ? "Cancel" : "Record Shortcut") {
                            store.isCapturingShortcut ? store.endShortcutCapture() : store.beginShortcutCapture()
                        }
                        .buttonStyle(GhostButtonStyle())
                        Spacer()
                    }
                    Text("Hold it to talk, or press to start and stop in toggle mode. Combos like \u{2318}K or \u{2318}\u{2325}Space work, and so do bare modifiers like Right Option (press and release it alone while recording).")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
                card {
                    HStack {
                        sectionLabel("Microphone priority")
                        Spacer()
                        if !store.micPriority.isEmpty {
                            Button("System Default") { store.resetMicPriority() }
                                .buttonStyle(GhostButtonStyle())
                        }
                    }
                    if store.connectedMics.isEmpty {
                        Text("No input devices found")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.dsMuted)
                    }
                    ForEach(store.connectedMics) { mic in
                        HStack(spacing: 10) {
                            Button {
                                store.promoteMic(mic.uid)
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.dsMuted)
                                    .frame(width: 26, height: 26)
                                    .background(Color.dsInk2, in: Circle())
                                    .overlay(Circle().strokeBorder(Color.dsLine, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help("Prefer this microphone")
                            Text(mic.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.dsPaper)
                            Spacer()
                            if store.activeMicUID == mic.uid {
                                tag("Active", color: .dsAccent)
                            } else if store.activeMicUID == nil, mic.uid == store.connectedMics.first?.uid {
                                tag("System default", color: .dsMuted)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Text("Recording binds the highest listed microphone that is connected; unplugged ones are skipped. With no priority set, the system default input is used.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
                card {
                    HStack {
                        sectionLabel("Learning")
                        Spacer()
                        chip(store.learningEnabled ? "On" : "Off", selected: store.learningEnabled) {
                            store.learningEnabled.toggle()
                        }
                    }
                    Text(store.learnedSummary)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.dsMuted)
                    Text("After each dictation, FreeSpeech watches how you edit the inserted text (locally, via Accessibility) and learns your corrections. A fix seen twice becomes an automatic rule and biases future transcription.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                    Button("Reset Learned Corrections") { store.resetLearning() }
                        .buttonStyle(GhostButtonStyle())
                }
                card {
                    sectionLabel("Model")
                    if store.installedModels.isEmpty {
                        Text("No models installed — run ./build.sh")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.dsMuted)
                    }
                    ForEach(store.installedModels, id: \.self) { model in
                        selectableRow(
                            title: model,
                            subtitle: modelSubtitle(model),
                            selected: store.modelName == model
                        ) { store.modelName = model }
                    }
                }
                card {
                    sectionLabel("Post-processing")
                    ForEach(PostProcessingMode.allCases, id: \.self) { mode in
                        selectableRow(
                            title: mode.displayName,
                            subtitle: mode.detail,
                            selected: store.postProcessing == mode,
                            disabled: mode.needsLanguageModel && !store.languageModelAvailable
                        ) { store.postProcessing = mode }
                    }
                    if !store.languageModelAvailable {
                        Text("Apple Intelligence is unavailable, so on-device rewrite modes are disabled. Enable it in System Settings > Apple Intelligence & Siri.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsFaint)
                    }
                    if store.postProcessing == .tone {
                        HStack(spacing: 8) {
                            ForEach(RewriteTone.allCases, id: \.self) { tone in
                                chip(tone.displayName, selected: store.tone == tone) {
                                    store.tone = tone
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                card {
                    sectionLabel("Vocabulary")
                    TextField("Names and terms you often say", text: $store.vocabularyHint)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.dsPaper)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Color.dsInk2, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                                .strokeBorder(Color.dsLine, lineWidth: 1))
                    Text("Steers transcription toward names and jargon you use, e.g. \"Caden Warren, Claude Code\".")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 680)
        .background(Color.dsInk0)
        .onAppear { store.refresh() }
        .onDisappear { store.endShortcutCapture() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FREESPEECH")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(Color.dsAccent)
            Text("Settings")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(Color.dsPaper)
        }
        .padding(.top, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.dsInk1, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .strokeBorder(Color.dsLine, lineWidth: 1))
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .kerning(1.0)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.dsInk2, in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .kerning(1.2)
            .foregroundStyle(Color.dsMuted)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.dsAccent : Color.dsPaper)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Color.dsInk2, in: Capsule())
                .overlay(Capsule().strokeBorder(
                    selected ? Color.dsAccent.opacity(0.6) : Color.dsLine, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    private func selectableRow(
        title: String, subtitle: String, selected: Bool,
        disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(selected ? Color.dsAccent : Color.clear)
                    .overlay(Circle().strokeBorder(
                        selected ? Color.dsAccent : Color.dsFaint, lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(disabled ? Color.dsFaint : Color.dsPaper)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .background(
                selected ? Color.dsInk3 : Color.clear,
                in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    private func modelSubtitle(_ model: String) -> String {
        let url = AppPaths.modelFile(named: model)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        return size.isEmpty ? "whisper ggml model" : "whisper ggml model, \(size)"
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private let makeStore: () -> SettingsStore

    init(makeStore: @escaping () -> SettingsStore) {
        self.makeStore = makeStore
    }

    func show() {
        if window == nil {
            let store = makeStore()
            let hosting = NSHostingController(rootView: SettingsView(store: store))
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)  // Greenlight is dark-only
            w.backgroundColor = DS.ink0
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("settings window opened")
    }
}
