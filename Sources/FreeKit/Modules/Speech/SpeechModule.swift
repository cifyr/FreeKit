import AppKit
import SwiftUI
import FreeKitCore

// The original dictation app this suite grew from, wrapped as the Speech module.
// All pipeline behavior (recording, transcription, insertion, history,
// learning, onboarding) is unchanged; only hotkey installation moved from two
// private event taps to the shared EventTapHub.
final class SpeechModule: NSObject, AppModule {
    let info = ModuleCatalog.speech

    private let settings: Settings
    private let hub: EventTapHub
    private let permissionCoach: PermissionCoachController
    // Suite-level retry of the shared event tap (used by onboarding's
    // permission step, which previously re-installed the private taps).
    private let ensureEventTap: () -> Void

    private var machine = DictationStateMachine()
    private var micHotkeyToken: EventTapHub.HotkeyToken?
    private var systemHotkeyToken: EventTapHub.HotkeyToken?
    private let recorder = AudioRecorder()
    private let systemRecorder = SystemAudioRecorder()
    // Which capture the current session uses; the machine guards cross-source events.
    private var activeSource: AudioSource = .microphone
    private let engine: TranscriptionEngine = WhisperCppEngine()
    // Second engine for the tinydiarize pass; loaded lazily, only ever used for
    // speaker-turn timestamps (its transcript text is discarded).
    private let diarizer: TranscriptionEngine = WhisperCppEngine()
    private let inserter = TextInserter()
    private let postProcessor = PostProcessor()
    private let modelDownloader = ModelDownloader()
    private let updateManager = UpdateManager()
    private weak var onboardingStore: OnboardingStore?
    private let learningStore = LearningStore(fileURL: AppPaths.learningFile)
    private let historyStore = HistoryStore(fileURL: AppPaths.historyFile)
    private lazy var editWatcher = EditWatcher(store: learningStore)
    private var historyWindow: HistoryWindowController!
    // Frontmost app when recording started: drives the per-app rewrite profile.
    private var pendingTargetBundleID: String?
    private var hud: HUDController!
    private var statusBar: StatusBarController!
    private var settingsStore: SettingsStore?
    private var onboardingWindow: OnboardingWindowController!
    // Set while the onboarding practice step is active: transcripts route here instead
    // of being inserted, so the user learns the hotkey without pasting into a real field.
    private var onPracticeTranscript: ((String?) -> Void)?

    // Serial queue: model load runs first, transcriptions queue behind it, so the
    // model loads once at launch and stays warm.
    private let whisperQueue = DispatchQueue(label: "com.cadenwarren.freespeech.whisper")
    private static let transcriptionTimeout: TimeInterval = 30

    private var activated = false

    init(settings: Settings, hub: EventTapHub, permissionCoach: PermissionCoachController,
         ensureEventTap: @escaping () -> Void) {
        self.settings = settings
        self.hub = hub
        self.permissionCoach = permissionCoach
        self.ensureEventTap = ensureEventTap
        super.init()
    }

    // MARK: - AppModule

    func activate() {
        if !activated {
            buildRuntime()
            activated = true
        }
        installHotkey()
        // On first run, onboarding drives the permission prompts; don't fire them behind it.
        if settings.hasCompletedOnboarding {
            Permissions.requestMicrophone { granted in
                if !granted {
                    Log.error("microphone permission not granted — dictation will fail until enabled")
                }
            }
        }
        loadModel()
        if !settings.hasCompletedOnboarding {
            onboardingWindow.show()
        }
    }

    func deactivate() {
        if let micHotkeyToken { hub.unregister(micHotkeyToken) }
        if let systemHotkeyToken { hub.unregister(systemHotkeyToken) }
        micHotkeyToken = nil
        systemHotkeyToken = nil
        recorder.stop()
        systemRecorder.stop()
        hud?.dismiss()
        machine = DictationStateMachine()
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        statusBar?.setVisible(visible)
    }

    var settingsPopupSize: NSSize { NSSize(width: 560, height: 680) }
    // Speech predates the suite and keeps its original tabbed settings view,
    // hosted edge to edge in the popup instead of the shared header/scroll.
    var popupUsesOwnChrome: Bool { true }

    func openSettings() {
        guard activated else { return }
        ControlCenterPresenter.shared.present(moduleID: info.id)
    }

    func makeSettingsPane() -> AnyView {
        let store = settingsStore ?? makeSettingsStore()
        settingsStore = store
        return AnyView(SettingsView(store: store, updates: store.updates))
    }

    private func makeSettingsStore() -> SettingsStore {
        SettingsStore(
            settings: settings,
            languageModelAvailable: postProcessor.languageModelAvailable,
            learningStore: learningStore,
            updates: updateManager,
            onHotkeyChanged: { [weak self] in self?.installHotkey() },
            onModelChanged: { [weak self] in self?.applySettings() })
    }

    // MARK: - Runtime construction (once, on first activate)

    private func buildRuntime() {
        hud = HUDController()
        hud.onAutoDismiss = { [weak self] in
            guard let self else { return }
            if case .error = self.machine.state {
                self.perform(self.machine.handle(.errorDismissed, mode: self.settings.mode))
            }
        }
        statusBar = StatusBarController(
            settings: settings, languageModelAvailable: postProcessor.languageModelAvailable)
        statusBar.onSettingsChanged = { [weak self] in self?.applySettings() }
        statusBar.onOpenSettings = { [weak self] in self?.openSettings() }
        onboardingWindow = OnboardingWindowController { [weak self] close in
            guard let self else { fatalError("onboarding store requested after teardown") }
            let store = OnboardingStore(settings: self.settings, deps: OnboardingDeps(
                microphoneAuthorized: { Permissions.microphoneAuthorized() },
                requestMicrophone: { completion in
                    Permissions.requestMicrophone { granted in
                        // A previously-denied mic never re-prompts; guide the
                        // user to the toggle instead of failing silently.
                        if !granted, Permissions.microphoneDenied() {
                            self.permissionCoach.show(.microphone)
                        }
                        completion(granted)
                    }
                },
                accessibilityTrusted: { Permissions.accessibilityTrusted(promptIfNeeded: false) },
                requestAccessibility: {
                    let trusted = Permissions.accessibilityTrusted(promptIfNeeded: true)
                    if !trusted { self.permissionCoach.show(.accessibility) }
                    return trusted
                },
                installHotkey: { self.ensureEventTap() },
                beginPractice: { handler in self.onPracticeTranscript = handler },
                endPractice: { self.onPracticeTranscript = nil },
                onFinished: close))
            self.onboardingStore = store
            return store
        }
        historyWindow = HistoryWindowController { [weak self] in
            guard let self else { fatalError("history model requested after teardown") }
            return HistoryViewModel(store: self.historyStore) { text in
                // Hide our window first so the paste lands in the user's app.
                self.historyWindow.hide()
                NSApp.hide(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    do {
                        try self.inserter.insert(text, copyToClipboard: self.settings.copyToClipboard)
                    } catch {
                        Log.error("history re-insert failed: \(error.localizedDescription)")
                        self.hud.show(.error(error.localizedDescription))
                    }
                }
            }
        }
        statusBar.onOpenHistory = { [weak self] in self?.historyWindow.show() }
        statusBar.onUndoLastDictation = { [weak self] in
            guard let self else { return }
            do {
                try self.inserter.undoLastInsertion()
            } catch {
                Log.error("undo failed: \(error.localizedDescription)")
                self.hud.show(.error(error.localizedDescription))
            }
        }
        hud.hudPosition = settings.hudPosition
        hud.hudStyle = settings.hudStyle

        let onMaxDuration: () -> Void = { [weak self] in
            guard let self else { return }
            self.perform(self.machine.handle(.recordingTimedOut, mode: self.settings.mode))
        }
        recorder.onLevel = { [weak self] level in self?.hud.updateLevel(level) }
        recorder.onMaxDuration = onMaxDuration
        systemRecorder.onLevel = { [weak self] level in self?.hud.updateLevel(level) }
        systemRecorder.onMaxDuration = onMaxDuration
    }

    // MARK: - Accessibility state relay (suite owns the shared tap)

    func noteAccessibilityMissing() {
        showError("Accessibility not granted — enable FreeKit in System Settings > Privacy & Security > Accessibility")
    }

    func noteAccessibilityGranted() {
        guard activated else { return }
        perform(machine.handle(.errorDismissed, mode: settings.mode))
        hud.dismiss()
    }

    // MARK: - Hotkeys

    private func installHotkey() {
        let mic = settings.hotkey
        if let micHotkeyToken {
            hub.update(micHotkeyToken, preset: mic)
        } else {
            micHotkeyToken = hub.register(preset: mic, label: "speech.mic") { [weak self] direction in
                guard let self else { return }
                let event: DictationEvent = direction == .down
                    ? .hotkeyDown(.microphone) : .hotkeyUp(.microphone)
                self.perform(self.machine.handle(event, mode: self.settings.mode))
            }
        }

        let system = settings.systemAudioHotkey
        guard mic.keyCode != system.keyCode || mic.modifiers != system.modifiers
                || mic.kind != system.kind else {
            Log.error("system audio hotkey \(system.displayName) collides with the mic hotkey, not installing it")
            showError("System audio hotkey matches the mic hotkey — pick a different one in Settings")
            if let systemHotkeyToken { hub.unregister(systemHotkeyToken) }
            systemHotkeyToken = nil
            return
        }
        if let systemHotkeyToken {
            hub.update(systemHotkeyToken, preset: system)
        } else {
            systemHotkeyToken = hub.register(preset: system, label: "speech.system") { [weak self] direction in
                guard let self else { return }
                let event: DictationEvent = direction == .down
                    ? .hotkeyDown(.systemAudio) : .hotkeyUp(.systemAudio)
                self.perform(self.machine.handle(event, mode: self.settings.mode))
            }
        }
    }

    // MARK: - Model

    private func loadModel() {
        let url = AppPaths.modelFile(named: settings.modelName)
        guard url.path != loadedModelPath else { return }
        loadedModelPath = url.path
        if FileManager.default.fileExists(atPath: url.path) {
            loadModelFile(url)
        } else {
            // First run of a shared copy: fetch the model once, then load it.
            downloadThenLoad(name: settings.modelName, to: url)
        }
    }

    private func loadModelFile(_ url: URL) {
        whisperQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.engine.loadModel(at: url)
            } catch {
                Log.error("model load failed: \(error.localizedDescription)")
                DispatchQueue.main.async { self.showError(error.localizedDescription) }
            }
        }
    }

    private func downloadThenLoad(name: String, to url: URL) {
        Log.info("model \(name) not on disk, downloading once")
        setModelStatus("Downloading model 0%")
        modelDownloader.download(modelName: name, to: url, progress: { [weak self] frac in
            DispatchQueue.main.async { self?.setModelStatus("Downloading model \(Int(frac * 100))%") }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let file):
                    self.setModelStatus(nil)
                    self.loadModelFile(file)
                case .failure(let error):
                    self.setModelStatus(nil)
                    self.showError("Model download failed: \(error.localizedDescription). Check your connection, then reopen FreeKit.")
                }
            }
        })
    }

    private func setModelStatus(_ text: String?) {
        onboardingStore?.modelStatus = text
        statusBar.showTransientStatus(text)
    }

    private func applySettings() {
        installHotkey()
        hud.hudPosition = settings.hudPosition
        hud.hudStyle = settings.hudStyle
        loadModel()
        ensureDiarizerModelDownloaded()
        statusBar.update(state: machine.state)
    }

    // Covers enabling split-speakers from the menu bar, where no settings window
    // exists to drive the one-time tinydiarize download.
    private var diarizerDownloadInFlight = false
    private func ensureDiarizerModelDownloaded() {
        guard settings.splitSpeakersEnabled, !diarizerDownloadInFlight else { return }
        let name = FreeKitCore.Settings.diarizerModelName
        let destination = AppPaths.modelFile(named: name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        diarizerDownloadInFlight = true
        Log.info("split speakers enabled without \(name) on disk, downloading")
        statusBar.showTransientStatus("Downloading speaker model\u{2026}")
        modelDownloader.download(
            modelName: name, to: destination,
            progress: { [weak self] fraction in
                DispatchQueue.main.async {
                    self?.statusBar.showTransientStatus(
                        "Downloading speaker model\u{2026} \(Int(fraction * 100))%")
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.diarizerDownloadInFlight = false
                    self.statusBar.showTransientStatus(nil)
                    if case .failure(let error) = result {
                        Log.error("speaker model download failed: \(error.localizedDescription)")
                        self.hud.show(.error("Speaker model download failed — toggle Split Speakers to retry"))
                    }
                }
            })
    }
    private var loadedModelPath: String = ""

    // MARK: - Pipeline

    private func perform(_ action: DictationAction) {
        statusBar.update(state: machine.state)
        switch action {
        case .startRecording(let source):
            startRecording(source: source)
        case .stopAndTranscribe:
            stopAndTranscribe()
        case .abortRecording(let reason):
            // Never leave any capture hot after an error, whichever source ran.
            recorder.stop()
            systemRecorder.stop()
            hud.show(.error(reason))
        case .showError(let reason):
            hud.show(.error(reason))
        case .becameIdle:
            break
        case .none:
            break
        }
    }

    private func startRecording(source: AudioSource) {
        activeSource = source
        pendingTargetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        captureScreenContext()
        SoundCues.play(.start, enabled: settings.soundCuesEnabled)
        switch source {
        case .microphone:
            guard Permissions.microphoneAuthorized() else {
                permissionCoach.show(.microphone)
                perform(machine.handle(.recordingFailed("Microphone not granted — enable FreeKit in System Settings > Privacy & Security > Microphone"), mode: settings.mode))
                return
            }
            // HUD first: it must appear the instant the hotkey fires.
            hud.show(.recording(.microphone))
            do {
                try recorder.start(
                    maxSeconds: settings.maxRecordingSeconds,
                    device: AudioDevices.preferredDevice(priority: settings.micPriority))
            } catch {
                Log.error("recording start failed: \(error.localizedDescription)")
                perform(machine.handle(.recordingFailed(error.localizedDescription), mode: settings.mode))
            }

        case .systemAudio:
            // Screen Recording permission is requested lazily, only for this mode.
            guard Permissions.screenRecordingAuthorized(requestIfNeeded: true) else {
                permissionCoach.show(.screenRecording)
                perform(machine.handle(.recordingFailed(SystemAudioError.permissionDenied.errorDescription ?? "Screen Recording not granted"), mode: settings.mode))
                return
            }
            hud.show(.recording(.systemAudio))
            systemRecorder.start(maxSeconds: settings.maxRecordingSeconds) { [weak self] error in
                guard let self, let error else { return }
                self.perform(self.machine.handle(
                    .recordingFailed(error.localizedDescription), mode: self.settings.mode))
            }
        }
    }

    // Reads names visible in the focused field/window while the user is still
    // speaking, so the terms are ready by transcription time at zero latency cost.
    private var pendingContextTerms: [String] = []
    private let contextQueue = DispatchQueue(
        label: "com.cadenwarren.freespeech.screencontext", qos: .userInitiated)

    private func captureScreenContext() {
        pendingContextTerms = []
        guard settings.screenContextEnabled else { return }
        contextQueue.async { [weak self] in
            guard let self else { return }
            let terms = AXFieldReader.screenContextText()
                .map { ScreenContext.properNouns(in: $0) } ?? []
            if !terms.isEmpty {
                Log.info("screen context terms: \(terms.joined(separator: ", "))")
            }
            DispatchQueue.main.async { self.pendingContextTerms = terms }
        }
    }

    private func stopAndTranscribe() {
        let samples = activeSource == .systemAudio ? systemRecorder.stop() : recorder.stop()
        hud.show(.transcribing)

        let stoppedAt = CFAbsoluteTimeGetCurrent()
        let contextTerms = pendingContextTerms
        whisperQueue.async { [weak self] in
            guard let self else { return }

            // Skip whisper entirely for silence: avoids garbage output and wasted work.
            let peak = samples.map(abs).max() ?? 0
            if peak < 0.005 {
                Log.info("no speech detected (peak amplitude \(peak)), skipping transcription")
                DispatchQueue.main.async { self.finish(transcript: nil, stoppedAt: stoppedAt) }
                return
            }

            do {
                // Learned terms extend the vocabulary hint so whisper hears the
                // user's words right the first time.
                var hint = self.settings.vocabularyHint
                let learnedTerms = self.learningStore.vocabularyTerms()
                    .filter { !hint.localizedCaseInsensitiveContains($0) }
                if !learnedTerms.isEmpty {
                    hint += " " + learnedTerms.joined(separator: ", ") + "."
                }
                // Names visible on screen when recording started (email thread,
                // chat window) bias whisper toward what the user is replying to.
                let screenTerms = contextTerms
                    .filter { !hint.localizedCaseInsensitiveContains($0) }
                if !screenTerms.isEmpty {
                    hint += " " + screenTerms.joined(separator: ", ") + "."
                }
                let raw: String
                let splitSpeakers = self.activeSource == .systemAudio
                    && self.settings.splitSpeakersEnabled
                    && self.ensureDiarizerLoaded()
                if splitSpeakers {
                    // Two passes: the accurate model for word-timestamped text,
                    // tinydiarize only for the times where the voice changes.
                    let segments = try self.engine.transcribeSegments(
                        samples: samples, timeout: Self.transcriptionTimeout,
                        beamSize: 1, vocabularyHint: hint,
                        language: self.settings.language,
                        detectSpeakerTurns: false, tokenTimestamps: true)
                    let turnSegments = try self.diarizer.transcribeSegments(
                        samples: samples, timeout: Self.transcriptionTimeout,
                        beamSize: 1, vocabularyHint: nil,
                        language: "en", detectSpeakerTurns: true, tokenTimestamps: false)
                    let turns = turnSegments.filter(\.speakerTurnNext).map(\.end)
                    let pieces = segments.flatMap(\.tokens)
                        .map { TimedSegment(start: $0.start, end: $0.end, text: $0.text) }
                    Log.info("speaker split: \(turns.count) turn(s) detected across \(pieces.count) words")
                    raw = SpeakerSplitter.merged(pieces: pieces, turnTimes: turns)
                } else {
                    raw = try self.engine.transcribe(
                        samples: samples, timeout: Self.transcriptionTimeout,
                        beamSize: 1, vocabularyHint: hint, language: self.settings.language)
                }
                // Per-app profile: the app being dictated into can override the mode.
                let mode = self.settings.postProcessing(forApp: self.pendingTargetBundleID)
                // "Do nothing" means raw whisper output, only trimmed so pasting is sane.
                var text: String? = mode == .off
                    ? raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    : (splitSpeakers
                        ? TranscriptCleaner.cleanPreservingLines(raw)
                        : TranscriptCleaner.clean(raw))
                if let t = text, mode != .off {
                    // Deterministic transforms, all effectively free: learned rules,
                    // the user's dictionary, filler removal, then spoken commands
                    // (so "scratch that" sees the final wording).
                    var transformed = self.learningStore.apply(to: t)
                    transformed = TextReplacements.apply(
                        rules: self.settings.customReplacements, to: transformed)
                    if self.settings.fillerStrippingEnabled {
                        transformed = FillerWords.strip(transformed)
                    }
                    if self.settings.spokenCommandsEnabled {
                        transformed = SpokenCommands.apply(to: transformed)
                    }
                    text = transformed
                }
                if text?.isEmpty == true { text = nil }
                if let cleaned = text, mode.needsLanguageModel {
                    if splitSpeakers {
                        // Rewrites would merge lines and lose the speaker turns.
                        Log.info("skipping \(mode.rawValue) rewrite for speaker-split transcript")
                    } else {
                        DispatchQueue.main.async { self.hud.show(.processing) }
                        text = self.postProcessor.process(cleaned, mode: mode, tone: self.settings.tone)
                    }
                }
                let result = text
                DispatchQueue.main.async { self.finish(transcript: result, stoppedAt: stoppedAt) }
            } catch {
                Log.error("transcription failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.perform(self.machine.handle(
                        .transcriptionFailed(error.localizedDescription), mode: self.settings.mode))
                }
            }
        }
    }

    // Loads the tinydiarize model once, on the whisper queue. Missing model or
    // load failure degrades to an unsplit transcript, never a failed dictation.
    private func ensureDiarizerLoaded() -> Bool {
        if diarizer.isLoaded { return true }
        let url = AppPaths.modelFile(named: FreeKitCore.Settings.diarizerModelName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.error("split speakers enabled but \(url.lastPathComponent) is missing — re-toggle the setting to download it")
            return false
        }
        do {
            try diarizer.loadModel(at: url)
            return true
        } catch {
            Log.error("diarizer model load failed: \(error.localizedDescription)")
            return false
        }
    }

    private func finish(transcript: String?, stoppedAt: CFAbsoluteTime) {
        // Onboarding practice: show what was heard in the setup window, never insert.
        if let practice = onPracticeTranscript {
            practice(transcript)
            hud.show(transcript == nil ? .error("No speech detected") : .success)
            _ = machine.handle(.transcriptionSucceeded, mode: settings.mode)
            statusBar.update(state: machine.state)
            return
        }
        guard let transcript else {
            hud.show(.error("No speech detected"))
            SoundCues.play(.error, enabled: settings.soundCuesEnabled)
            _ = machine.handle(.transcriptionSucceeded, mode: settings.mode)
            statusBar.update(state: machine.state)
            return
        }
        do {
            let inserted = try inserter.insert(transcript, copyToClipboard: settings.copyToClipboard)
            Log.info(String(format: "stop-to-insert latency: %.2fs", CFAbsoluteTimeGetCurrent() - stoppedAt))
            if inserted.isEmpty {
                // Everything the user said was already at the caret.
                hud.show(.error("Nothing new to insert"))
            } else {
                hud.show(.success)
                SoundCues.play(.inserted, enabled: settings.soundCuesEnabled)
                if settings.historyEnabled {
                    historyStore.append(HistoryEntry(
                        timestamp: Date(),
                        text: inserted,
                        appName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown",
                        source: activeSource.rawValue))
                }
            }
            perform(machine.handle(.transcriptionSucceeded, mode: settings.mode))
            if settings.learningEnabled, !inserted.isEmpty {
                editWatcher.watch(inserted: inserted)
            }
        } catch {
            Log.error("insertion failed: \(error.localizedDescription)")
            SoundCues.play(.error, enabled: settings.soundCuesEnabled)
            perform(machine.handle(.transcriptionFailed(error.localizedDescription), mode: settings.mode))
        }
    }

    private func showError(_ message: String) {
        guard activated else { return }
        // Force the machine into a visible, recoverable error state from any point.
        switch machine.state {
        case .recording:
            perform(machine.handle(.recordingFailed(message), mode: settings.mode))
        case .transcribing:
            perform(machine.handle(.transcriptionFailed(message), mode: settings.mode))
        default:
            hud.show(.error(message))
            statusBar.update(state: .error(message))
        }
    }
}
