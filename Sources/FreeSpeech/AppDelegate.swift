import AppKit
import FreeSpeechCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private var machine = DictationStateMachine()
    private let hotkey = HotkeyManager()
    private let recorder = AudioRecorder()
    private let engine: TranscriptionEngine = WhisperCppEngine()
    private let inserter = TextInserter()
    private let postProcessor = PostProcessor()
    private let learningStore = LearningStore(fileURL: AppPaths.learningFile)
    private lazy var editWatcher = EditWatcher(store: learningStore)
    private var hud: HUDController!
    private var statusBar: StatusBarController!
    private var settingsWindow: SettingsWindowController!

    // Serial queue: model load runs first, transcriptions queue behind it, so the
    // model loads once at launch and stays warm.
    private let whisperQueue = DispatchQueue(label: "com.cadenwarren.freespeech.whisper")
    private static let transcriptionTimeout: TimeInterval = 30

    private var accessibilityPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.setLogFile(AppPaths.logFile)
        Log.info("FreeSpeech launching (pid \(ProcessInfo.processInfo.processIdentifier))")

        hud = HUDController()
        hud.onAutoDismiss = { [weak self] in
            guard let self else { return }
            if case .error = self.machine.state {
                self.perform(self.machine.handle(.errorDismissed, mode: self.settings.mode))
            }
        }
        statusBar = StatusBarController(settings: settings)
        statusBar.onSettingsChanged = { [weak self] in self?.applySettings() }
        settingsWindow = SettingsWindowController { [weak self] in
            guard let self else { fatalError("settings store requested after teardown") }
            return SettingsStore(
                settings: self.settings,
                languageModelAvailable: self.postProcessor.languageModelAvailable,
                learningStore: self.learningStore,
                onHotkeyChanged: { self.installHotkey() },
                onModelChanged: { self.applySettings() })
        }
        statusBar.onOpenSettings = { [weak self] in self?.settingsWindow.show() }

        recorder.onLevel = { [weak self] level in self?.hud.updateLevel(level) }
        recorder.onMaxDuration = { [weak self] in
            guard let self else { return }
            self.perform(self.machine.handle(.recordingTimedOut, mode: self.settings.mode))
        }
        hotkey.onEvent = { [weak self] direction in
            guard let self else { return }
            let event: DictationEvent = direction == .down ? .hotkeyDown : .hotkeyUp
            self.perform(self.machine.handle(event, mode: self.settings.mode))
        }

        Permissions.requestMicrophone { granted in
            if !granted {
                Log.error("microphone permission not granted — dictation will fail until enabled")
            }
        }
        installHotkeyOrPollForAccessibility()
        loadModel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        recorder.stop()
        Log.info("FreeSpeech terminating")
    }

    // MARK: - Setup

    private func installHotkeyOrPollForAccessibility() {
        if Permissions.accessibilityTrusted(promptIfNeeded: true) {
            installHotkey()
            return
        }
        showError("Accessibility not granted — enable FreeSpeech in System Settings > Privacy & Security > Accessibility")
        Permissions.openAccessibilitySettings()
        // Poll until granted: AX trust can change at any time and there is no notification API.
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, Permissions.accessibilityTrusted(promptIfNeeded: false) else { return }
            self.accessibilityPollTimer?.invalidate()
            self.accessibilityPollTimer = nil
            Log.info("accessibility granted, installing hotkey")
            self.installHotkey()
            self.perform(self.machine.handle(.errorDismissed, mode: self.settings.mode))
            self.hud.dismiss()
        }
    }

    private func installHotkey() {
        do {
            try hotkey.start(preset: settings.hotkey)
        } catch {
            Log.error("hotkey installation failed: \(error.localizedDescription)")
            showError(error.localizedDescription)
        }
    }

    private func loadModel() {
        let url = AppPaths.modelFile(named: settings.modelName)
        loadedModelPath = url.path
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

    private func applySettings() {
        installHotkey()
        if AppPaths.modelFile(named: settings.modelName).path != loadedModelPath {
            loadModel()
        }
        statusBar.update(state: machine.state)
    }
    private var loadedModelPath: String = ""

    // MARK: - Pipeline

    private func perform(_ action: DictationAction) {
        statusBar.update(state: machine.state)
        switch action {
        case .startRecording:
            startRecording()
        case .stopAndTranscribe:
            stopAndTranscribe()
        case .abortRecording(let reason):
            recorder.stop()
            hud.show(.error(reason))
        case .showError(let reason):
            hud.show(.error(reason))
        case .becameIdle:
            break
        case .none:
            break
        }
    }

    private func startRecording() {
        guard Permissions.microphoneAuthorized() else {
            Permissions.openMicrophoneSettings()
            perform(machine.handle(.recordingFailed("Microphone not granted — enable FreeSpeech in System Settings > Privacy & Security > Microphone"), mode: settings.mode))
            return
        }
        // HUD first: it must appear the instant the hotkey fires.
        hud.show(.recording)
        do {
            try recorder.start(
                maxSeconds: settings.maxRecordingSeconds,
                device: AudioDevices.preferredDevice(priority: settings.micPriority))
        } catch {
            Log.error("recording start failed: \(error.localizedDescription)")
            perform(machine.handle(.recordingFailed(error.localizedDescription), mode: settings.mode))
        }
    }

    private func stopAndTranscribe() {
        let samples = recorder.stop()
        hud.show(.transcribing)

        let stoppedAt = CFAbsoluteTimeGetCurrent()
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
                let raw = try self.engine.transcribe(
                    samples: samples, timeout: Self.transcriptionTimeout,
                    beamSize: 1, vocabularyHint: hint)
                let mode = self.settings.postProcessing
                // "Do nothing" means raw whisper output, only trimmed so pasting is sane.
                var text: String? = mode == .off
                    ? raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    : TranscriptCleaner.clean(raw)
                if let t = text, mode != .off {
                    // Learned corrections are deterministic and effectively free.
                    text = self.learningStore.apply(to: t)
                }
                if text?.isEmpty == true { text = nil }
                if let cleaned = text, mode.needsLanguageModel {
                    DispatchQueue.main.async { self.hud.show(.processing) }
                    text = self.postProcessor.process(cleaned, mode: mode, tone: self.settings.tone)
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

    private func finish(transcript: String?, stoppedAt: CFAbsoluteTime) {
        guard let transcript else {
            hud.show(.error("No speech detected"))
            _ = machine.handle(.transcriptionSucceeded, mode: settings.mode)
            statusBar.update(state: machine.state)
            return
        }
        do {
            try inserter.insert(transcript)
            Log.info(String(format: "stop-to-insert latency: %.2fs", CFAbsoluteTimeGetCurrent() - stoppedAt))
            hud.show(.success)
            perform(machine.handle(.transcriptionSucceeded, mode: settings.mode))
            if settings.learningEnabled {
                editWatcher.watch(inserted: transcript)
            }
        } catch {
            Log.error("insertion failed: \(error.localizedDescription)")
            perform(machine.handle(.transcriptionFailed(error.localizedDescription), mode: settings.mode))
        }
    }

    private func showError(_ message: String) {
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
