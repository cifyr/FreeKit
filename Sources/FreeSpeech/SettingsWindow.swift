import AppKit
import ServiceManagement
import SwiftUI
import FreeSpeechCore

extension AudioInputDevice: Identifiable {
    public var id: String { uid }
}

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case audio = "Audio"
    case text = "Text"
    case smarts = "Smarts"
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
    @Published var systemHotkey: HotkeyPreset {
        didSet {
            settings.systemAudioHotkey = systemHotkey
            onHotkeyChanged()
        }
    }
    @Published var copyToClipboard: Bool { didSet { settings.copyToClipboard = copyToClipboard } }
    @Published var modelName: String {
        didSet {
            settings.modelName = modelName
            onModelChanged()
        }
    }
    @Published var postProcessing: PostProcessingMode { didSet { settings.postProcessing = postProcessing } }
    @Published var tone: RewriteTone { didSet { settings.tone = tone } }
    @Published var vocabularyHint: String { didSet { settings.vocabularyHint = vocabularyHint } }
    enum ShortcutTarget { case microphone, systemAudio }
    @Published var capturingTarget: ShortcutTarget?
    @Published var installedModels: [String] = []
    @Published var connectedMics: [AudioInputDevice] = []
    @Published var micPriority: [String] { didSet { settings.micPriority = micPriority } }
    @Published var learningEnabled: Bool { didSet { settings.learningEnabled = learningEnabled } }
    @Published var screenContextEnabled: Bool { didSet { settings.screenContextEnabled = screenContextEnabled } }
    @Published var learnedSummary: String = ""
    @Published var spokenCommandsEnabled: Bool { didSet { settings.spokenCommandsEnabled = spokenCommandsEnabled } }
    @Published var fillerStrippingEnabled: Bool { didSet { settings.fillerStrippingEnabled = fillerStrippingEnabled } }
    @Published var historyEnabled: Bool { didSet { settings.historyEnabled = historyEnabled } }
    @Published var language: String { didSet { settings.language = language } }
    @Published var soundCuesEnabled: Bool { didSet { settings.soundCuesEnabled = soundCuesEnabled } }
    @Published var hudPosition: HUDPosition {
        didSet {
            settings.hudPosition = hudPosition
            onModelChanged()  // applySettings pushes the position to the HUD
        }
    }
    @Published var replacements: [(from: String, to: String)] = []
    @Published var newReplacementFrom: String = ""
    @Published var newReplacementTo: String = ""
    @Published var appProfiles: [(bundleID: String, appName: String, mode: PostProcessingMode)] = []
    @Published var launchAtLogin: Bool = false
    @Published var selectedTab: SettingsTab = .general
    @Published var splitSpeakers: Bool {
        didSet {
            settings.splitSpeakersEnabled = splitSpeakers
            if splitSpeakers { ensureDiarizerModel() }
        }
    }
    @Published var diarizerStatus: String = ""
    private let diarizerDownloader = ModelDownloader()

    let updates: UpdateManager

    let languageModelAvailable: Bool

    init(settings: FreeSpeechCore.Settings, languageModelAvailable: Bool,
         learningStore: LearningStore, updates: UpdateManager,
         onHotkeyChanged: @escaping () -> Void, onModelChanged: @escaping () -> Void) {
        self.settings = settings
        self.learningStore = learningStore
        self.updates = updates
        self.languageModelAvailable = languageModelAvailable
        self.onHotkeyChanged = onHotkeyChanged
        self.onModelChanged = onModelChanged
        _mode = Published(initialValue: settings.mode)
        _hotkey = Published(initialValue: settings.hotkey)
        _systemHotkey = Published(initialValue: settings.systemAudioHotkey)
        _copyToClipboard = Published(initialValue: settings.copyToClipboard)
        _modelName = Published(initialValue: settings.modelName)
        _postProcessing = Published(initialValue: settings.postProcessing)
        _tone = Published(initialValue: settings.tone)
        _vocabularyHint = Published(initialValue: settings.vocabularyHint)
        _micPriority = Published(initialValue: settings.micPriority)
        _learningEnabled = Published(initialValue: settings.learningEnabled)
        _screenContextEnabled = Published(initialValue: settings.screenContextEnabled)
        _spokenCommandsEnabled = Published(initialValue: settings.spokenCommandsEnabled)
        _fillerStrippingEnabled = Published(initialValue: settings.fillerStrippingEnabled)
        _historyEnabled = Published(initialValue: settings.historyEnabled)
        _language = Published(initialValue: settings.language)
        _soundCuesEnabled = Published(initialValue: settings.soundCuesEnabled)
        _hudPosition = Published(initialValue: settings.hudPosition)
        _splitSpeakers = Published(initialValue: settings.splitSpeakersEnabled)
        refresh()
    }

    // The tinydiarize model is fetched once, the first time the toggle goes on.
    private func ensureDiarizerModel() {
        let name = FreeSpeechCore.Settings.diarizerModelName
        let destination = AppPaths.modelFile(named: name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            diarizerStatus = ""
            return
        }
        diarizerStatus = "Downloading speaker model (one-time, ~490 MB)\u{2026}"
        diarizerDownloader.download(
            modelName: name, to: destination,
            progress: { [weak self] fraction in
                DispatchQueue.main.async {
                    self?.diarizerStatus = "Downloading speaker model\u{2026} \(Int(fraction * 100))%"
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.diarizerStatus = "Speaker model installed."
                    case .failure(let error):
                        Log.error("diarizer model download failed: \(error.localizedDescription)")
                        self.diarizerStatus = "Download failed: \(error.localizedDescription)"
                        self.splitSpeakers = false
                    }
                }
            })
    }

    func refresh() {
        installedModels = AppPaths.installedModels()
        // Priority devices first (in priority order), then the rest as connected.
        let connected = AudioDevices.inputDevices()
        let prioritized = micPriority.compactMap { uid in connected.first { $0.uid == uid } }
        connectedMics = prioritized + connected.filter { d in !micPriority.contains(d.uid) }
        refreshLearnedSummary()
        replacements = settings.customReplacements
        refreshAppProfiles()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Custom replacement dictionary

    func addReplacement() {
        let from = newReplacementFrom.trimmingCharacters(in: .whitespaces)
        let to = newReplacementTo.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty else { return }
        var rules = settings.customReplacements.filter { $0.from.lowercased() != from.lowercased() }
        rules.append((from: from, to: to))
        settings.customReplacements = rules
        Log.info("replacement added: \"\(from)\" -> \"\(to)\"")
        newReplacementFrom = ""
        newReplacementTo = ""
        replacements = rules
    }

    func removeReplacement(from: String) {
        settings.customReplacements = settings.customReplacements.filter { $0.from != from }
        replacements = settings.customReplacements
        Log.info("replacement removed: \"\(from)\"")
    }

    // MARK: - Per-app profiles

    var runningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return (bundleID: id, name: name)
            }
            .sorted { $0.name < $1.name }
    }

    func setProfile(bundleID: String, mode: PostProcessingMode?) {
        var profiles = settings.appProfiles
        profiles[bundleID] = mode?.rawValue
        settings.appProfiles = profiles
        Log.info("app profile: \(bundleID) -> \(mode?.rawValue ?? "removed")")
        refreshAppProfiles()
    }

    private func refreshAppProfiles() {
        let running = Dictionary(
            uniqueKeysWithValues: runningApps.map { ($0.bundleID, $0.name) })
        appProfiles = settings.appProfiles.compactMap { bundleID, raw in
            guard let mode = PostProcessingMode(rawValue: raw) else { return nil }
            return (bundleID: bundleID, appName: running[bundleID] ?? bundleID, mode: mode)
        }.sorted { $0.appName < $1.appName }
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            Log.info("launch at login set to \(launchAtLogin)")
        } catch {
            Log.error("launch at login change failed: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
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
    func beginShortcutCapture(for target: ShortcutTarget) {
        guard captureMonitor == nil else { return }
        capturingTarget = target
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
        capturingTarget = nil
        involvedModifiers = []
    }

    private func capture(_ keyCode: Int64, modifiers: HotkeyModifiers) {
        let target = capturingTarget
        endShortcutCapture()
        let preset = HotkeyPreset.custom(keyCode: keyCode, modifiers: modifiers)
        Log.info("shortcut captured for \(target == .systemAudio ? "system audio" : "mic"): \(preset.displayName) [keyCode \(keyCode), modifiers \(modifiers.rawValue)]")
        if target == .systemAudio {
            systemHotkey = preset
        } else {
            hotkey = preset
        }
    }
}

// Greenlight-styled settings: ink surfaces, hairlines, mono micro labels, red accent.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    // Observed directly: the store does not republish the manager's changes.
    @ObservedObject var updates: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                HStack(spacing: 8) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        chip(tab.rawValue, selected: store.selectedTab == tab) {
                            store.selectedTab = tab
                        }
                    }
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch store.selectedTab {
                    case .general: generalTab
                    case .audio: audioTab
                    case .text: textTab
                    case .smarts: smartsTab
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 480, height: 640)
        .background(Color.dsInk0)
        .onAppear { store.refresh() }
        .onDisappear { store.endShortcutCapture() }
    }

    @ViewBuilder private var generalTab: some View {
        activationCard
        feedbackCard
        updatesCard
    }

    @ViewBuilder private var audioTab: some View {
        micPriorityCard
        modelCard
        languageCard
        splitSpeakersCard
    }

    @ViewBuilder private var splitSpeakersCard: some View {
                card {
                    HStack {
                        sectionLabel("Split speakers (system audio)")
                        Spacer()
                        chip(store.splitSpeakers ? "On" : "Off", selected: store.splitSpeakers) {
                            store.splitSpeakers.toggle()
                        }
                    }
                    Text("System-audio captures get a line break whenever the voice changes — each speaker on their own line. Uses a second on-device pass, adding roughly one transcription's latency. English-focused. Rewrite modes are skipped for split transcripts.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                    if !store.diarizerStatus.isEmpty {
                        Text(store.diarizerStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dsMuted)
                    }
                }
    }

    @ViewBuilder private var textTab: some View {
        postProcessingCard
        dictationCard
        clipboardCard
        replacementCard
        perAppCard
    }

    @ViewBuilder private var smartsTab: some View {
        vocabularyCard
        learningCard
        historyCard
    }

    @ViewBuilder private var activationCard: some View {
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
                    sectionLabel("Hotkeys")
                    shortcutRow("Microphone", preset: store.hotkey, target: .microphone)
                    shortcutRow("System audio", preset: store.systemHotkey, target: .systemAudio)
                    Text("Hold to talk, or press to start and stop in toggle mode. Combos like \u{2318}K or \u{2318}\u{2325}Space work, and so do bare modifiers like Right Option (press and release it alone while recording). System audio captures what the Mac is playing — the other side of a call — and needs Screen Recording permission on first use.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
    }

    @ViewBuilder private var clipboardCard: some View {
                card {
                    HStack {
                        sectionLabel("Keep transcript on clipboard")
                        Spacer()
                        chip(store.copyToClipboard ? "On" : "Off", selected: store.copyToClipboard) {
                            store.copyToClipboard.toggle()
                        }
                    }
                    Text("On: every dictation stays on the clipboard after insertion, ready to paste again. Off: your previous clipboard contents are restored.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
    }

    @ViewBuilder private var micPriorityCard: some View {
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
    }

    @ViewBuilder private var learningCard: some View {
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
    }

    @ViewBuilder private var modelCard: some View {
                card {
                    sectionLabel("Model")
                    if store.installedModels.isEmpty {
                        Text("No models installed — run ./build.sh")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.dsMuted)
                    }
                    ForEach(ModelCatalog.ordered(store.installedModels), id: \.id) { info in
                        selectableRow(
                            title: info.name,
                            subtitle: modelSubtitle(info),
                            selected: store.modelName == info.id,
                            badge: info.recommended ? "Recommended" : nil
                        ) { store.modelName = info.id }
                    }
                }
    }

    @ViewBuilder private var postProcessingCard: some View {
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
    }

    @ViewBuilder private var vocabularyCard: some View {
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
                    Divider().overlay(Color.dsLine).padding(.vertical, 4)
                    HStack {
                        sectionLabel("Use on-screen context")
                        Spacer()
                        chip(store.screenContextEnabled ? "On" : "Off", selected: store.screenContextEnabled) {
                            store.screenContextEnabled.toggle()
                        }
                    }
                    Text("Reads names visible in the focused window when you start dictating — replying to Gurkaran makes \"Gurkaran\" transcribe correctly. Local only, nothing stored.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
    }

    @ViewBuilder private var dictationCard: some View {
                card {
                    sectionLabel("Dictation")
                    HStack {
                        Text("Spoken commands")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.dsPaper)
                        Spacer()
                        chip(store.spokenCommandsEnabled ? "On" : "Off", selected: store.spokenCommandsEnabled) {
                            store.spokenCommandsEnabled.toggle()
                        }
                    }
                    Text("\"new line\", \"new paragraph\" become breaks; \"scratch that\" discards what you said before it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                    HStack {
                        Text("Strip filler words")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.dsPaper)
                        Spacer()
                        chip(store.fillerStrippingEnabled ? "On" : "Off", selected: store.fillerStrippingEnabled) {
                            store.fillerStrippingEnabled.toggle()
                        }
                    }
                    Text("Removes um, uh, erm before inserting.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
    }

    @ViewBuilder private var languageCard: some View {
                card {
                    sectionLabel("Language")
                    HStack {
                        Text("Language")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.dsPaper)
                        Spacer()
                        Picker("", selection: $store.language) {
                            ForEach(TranscriptionLanguage.options, id: \.code) { option in
                                Text(option.name).tag(option.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                    Text("Auto-detect and non-English need a multilingual model (the default large-v3-turbo works; \".en\" models are English-only).")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
    }

    @ViewBuilder private var replacementCard: some View {
                card {
                    sectionLabel("Replacement dictionary")
                    ForEach(store.replacements, id: \.from) { rule in
                        HStack(spacing: 8) {
                            Text(rule.from)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Color.dsMuted)
                            Text("\u{2192}")
                                .foregroundStyle(Color.dsFaint)
                            Text(rule.to)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Color.dsPaper)
                            Spacer()
                            Button {
                                store.removeReplacement(from: rule.from)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.dsMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    HStack(spacing: 8) {
                        settingsField("heard as", text: $store.newReplacementFrom)
                        Text("\u{2192}").foregroundStyle(Color.dsFaint)
                        settingsField("replace with", text: $store.newReplacementTo)
                        Button("Add") { store.addReplacement() }
                            .buttonStyle(GhostButtonStyle())
                    }
                    Text("Always-on corrections of your own, applied on word boundaries alongside the auto-learned ones.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
    }

    @ViewBuilder private var perAppCard: some View {
                card {
                    sectionLabel("Per-app rewrite")
                    ForEach(store.appProfiles, id: \.bundleID) { profile in
                        HStack(spacing: 8) {
                            Text(profile.appName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.dsPaper)
                            Spacer()
                            Text(profile.mode.displayName.uppercased())
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .kerning(1.0)
                                .foregroundStyle(Color.dsAccent)
                            Button {
                                store.setProfile(bundleID: profile.bundleID, mode: nil)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.dsMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    Menu("Add rule for an open app\u{2026}") {
                        ForEach(store.runningApps, id: \.bundleID) { app in
                            Menu(app.name) {
                                ForEach(PostProcessingMode.allCases, id: \.self) { mode in
                                    Button(mode.displayName) {
                                        store.setProfile(bundleID: app.bundleID, mode: mode)
                                    }
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dsPaper)
                    .frame(maxWidth: 260)
                    Text("Overrides the rewrite mode when dictating into that app, e.g. grammar fixes in Mail but raw text in the terminal.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
    }

    @ViewBuilder private var feedbackCard: some View {
                card {
                    sectionLabel("Feedback and system")
                    HStack {
                        Text("Sound cues")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.dsPaper)
                        Spacer()
                        chip(store.soundCuesEnabled ? "On" : "Off", selected: store.soundCuesEnabled) {
                            store.soundCuesEnabled.toggle()
                        }
                    }
                    HStack {
                        Text("Launch at login")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.dsPaper)
                        Spacer()
                        chip(store.launchAtLogin ? "On" : "Off", selected: store.launchAtLogin) {
                            store.setLaunchAtLogin(!store.launchAtLogin)
                        }
                    }
                    Divider().overlay(Color.dsLine).padding(.vertical, 4)
                    sectionLabel("HUD position")
                    HStack(spacing: 8) {
                        ForEach(HUDPosition.allCases, id: \.self) { position in
                            chip(position.displayName, selected: store.hudPosition == position) {
                                store.hudPosition = position
                            }
                        }
                    }
                }
    }

    @ViewBuilder private var historyCard: some View {
                card {
                    HStack {
                        sectionLabel("History")
                        Spacer()
                        chip(store.historyEnabled ? "On" : "Off", selected: store.historyEnabled) {
                            store.historyEnabled.toggle()
                        }
                    }
                    Text("Local transcript history, browsable from the menu bar.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
    }

    @ViewBuilder private var updatesCard: some View {
                card {
                    HStack {
                        sectionLabel("Updates")
                        Spacer()
                        Text(updates.versionLine.uppercased())
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .kerning(1.0)
                            .foregroundStyle(Color.dsFaint)
                    }
                    Text(updateStatusText)
                        .font(.system(size: 13))
                        .foregroundStyle(updateStatusIsError ? Color.dsAccent : Color.dsMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(updateButtonTitle) {
                        switch updates.status {
                        case .updateAvailable, .rebuildAvailable:
                            updates.updateAndRelaunch()
                        default:
                            updates.check()
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(updateButtonDisabled)
                    Text("Pulls the latest source from GitHub, rebuilds (tests included), and relaunches. This and model downloads are the app's only network use.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsFaint)
                }
    }

    private var updateStatusText: String {
        switch updates.status {
        case .idle: return "Installed build \(updates.versionLine)."
        case .checking: return "Checking for updates\u{2026}"
        case .upToDate: return "Up to date."
        case .updateAvailable(let n): return "\(n) new commit\(n == 1 ? "" : "s") available."
        case .rebuildAvailable: return "Local source is newer than this build."
        case .updating(let step): return step
        case .failed(let message): return message
        }
    }

    private var updateStatusIsError: Bool {
        if case .failed = updates.status { return true }
        return false
    }

    private var updateButtonTitle: String {
        switch updates.status {
        case .updateAvailable: return "Update & Relaunch"
        case .rebuildAvailable: return "Rebuild & Relaunch"
        case .updating: return "Updating\u{2026}"
        case .checking: return "Checking\u{2026}"
        case .failed: return "Retry Check"
        default: return "Check for Updates"
        }
    }

    private var updateButtonDisabled: Bool {
        switch updates.status {
        case .checking, .updating: return true
        default: return false
        }
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

    private func shortcutRow(_ title: String, preset: HotkeyPreset, target: SettingsStore.ShortcutTarget) -> some View {
        let capturing = store.capturingTarget == target
        return HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dsMuted)
                .frame(width: 96, alignment: .leading)
            Text(capturing ? "PRESS A KEY\u{2026}" : preset.displayName.uppercased())
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .kerning(0.8)
                .foregroundStyle(capturing ? Color.dsAccent : Color.dsPaper)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Color.dsInk2, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                        .strokeBorder(capturing ? Color.dsAccent : Color.dsLine, lineWidth: 1))
            Button(capturing ? "Cancel" : "Record") {
                capturing ? store.endShortcutCapture() : store.beginShortcutCapture(for: target)
            }
            .buttonStyle(GhostButtonStyle())
            Spacer()
        }
    }

    private func settingsField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Color.dsPaper)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color.dsInk2, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
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
        disabled: Bool = false, badge: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(selected ? Color.dsAccent : Color.clear)
                    .overlay(Circle().strokeBorder(
                        selected ? Color.dsAccent : Color.dsFaint, lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(disabled ? Color.dsFaint : Color.dsPaper)
                        if let badge { tag(badge, color: .dsAccent) }
                    }
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

    // Dot meter like ●●●○○ for a 1...5 rating.
    private func meter(_ value: Int) -> String {
        let n = max(0, min(5, value))
        return String(repeating: "\u{25CF}", count: n) + String(repeating: "\u{25CB}", count: 5 - n)
    }

    private func modelSubtitle(_ info: ModelInfo) -> String {
        let url = AppPaths.modelFile(named: info.id)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        var line = "\(info.tagline)  ·  Accuracy \(meter(info.accuracy))  ·  Speed \(meter(info.speed))"
        if let size { line += "  ·  \(size)" }
        return line
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private let makeStore: () -> SettingsStore
    private(set) var store: SettingsStore?

    init(makeStore: @escaping () -> SettingsStore) {
        self.makeStore = makeStore
    }

    func show(tab: SettingsTab? = nil) {
        if window == nil {
            let store = makeStore()
            self.store = store
            let hosting = NSHostingController(
                rootView: SettingsView(store: store, updates: store.updates))
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
        if let tab { store?.selectedTab = tab }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("settings window opened")
    }
}
