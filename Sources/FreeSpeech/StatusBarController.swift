import AppKit
import FreeSpeechCore

// Menu bar icon reflects the pipeline state; menu exposes mode, hotkey, mic input,
// cleanup/rewrite, clipboard, quit.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settings: Settings
    private let languageModelAvailable: Bool
    var onSettingsChanged: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onUndoLastDictation: (() -> Void)?

    private var currentState: DictationState = .idle
    private var statusLine: String = "Idle"

    init(settings: Settings, languageModelAvailable: Bool) {
        self.settings = settings
        self.languageModelAvailable = languageModelAvailable
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        update(state: .idle)
    }

    // Overrides the menu/tooltip line with a transient message (e.g. model download
    // progress); passing nil restores the normal state line.
    func showTransientStatus(_ text: String?) {
        if let text {
            statusLine = text
            statusItem.button?.toolTip = text
        } else {
            update(state: currentState)
        }
    }

    func update(state: DictationState) {
        currentState = state
        let (symbol, description, line): (String, String, String)
        switch state {
        case .idle:
            (symbol, description, line) = ("mic", "FreeSpeech idle", "Idle — hold \(settings.hotkey.displayName)")
        case .recording(let source):
            (symbol, description, line) = (
                source == .systemAudio ? "speaker.wave.2.fill" : "mic.fill",
                "FreeSpeech recording",
                "Recording (\(source.displayName))…")
        case .transcribing:
            (symbol, description, line) = ("waveform", "FreeSpeech transcribing", "Transcribing…")
        case .error(let message):
            (symbol, description, line) = ("mic.slash", "FreeSpeech error", "Error: \(message)")
        }
        statusLine = line
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: symbol, accessibilityDescription: description)
            button.toolTip = line
        }
    }

    // Rebuild each time it opens so checkmarks and the connected-device list stay fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let modeMenu = NSMenu()
        for mode in ActivationMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = settings.mode == mode ? .on : .off
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Activation", action: nil, keyEquivalent: "")
        menu.addItem(modeItem)
        menu.setSubmenu(modeMenu, for: modeItem)

        let micMenu = NSMenu()
        // Empty UID represents "system default input"; matches Settings.micPriority == [].
        let selectedUID = settings.micPriority.first ?? ""
        let defaultItem = NSMenuItem(
            title: "System Default", action: #selector(selectMicInput(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = ""
        defaultItem.state = selectedUID.isEmpty ? .on : .off
        micMenu.addItem(defaultItem)
        let devices = AudioDevices.inputDevices()
        if !devices.isEmpty { micMenu.addItem(.separator()) }
        for device in devices {
            let item = NSMenuItem(
                title: device.name, action: #selector(selectMicInput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = selectedUID == device.uid ? .on : .off
            micMenu.addItem(item)
        }
        let micItem = NSMenuItem(title: "Mic Input", action: nil, keyEquivalent: "")
        menu.addItem(micItem)
        menu.setSubmenu(micMenu, for: micItem)

        let ppMenu = NSMenu()
        for mode in PostProcessingMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName, action: #selector(selectPostProcessing(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = settings.postProcessing == mode ? .on : .off
            // Rewrite modes need Apple Intelligence; disable them when it's unavailable.
            item.isEnabled = languageModelAvailable || !mode.needsLanguageModel
            ppMenu.addItem(item)
        }
        let ppItem = NSMenuItem(title: "Cleanup / Rewrite", action: nil, keyEquivalent: "")
        menu.addItem(ppItem)
        menu.setSubmenu(ppMenu, for: ppItem)

        let splitItem = NSMenuItem(
            title: "Split Speakers (System Audio)", action: #selector(toggleSplitSpeakers),
            keyEquivalent: "")
        splitItem.target = self
        splitItem.state = settings.splitSpeakersEnabled ? .on : .off
        menu.addItem(splitItem)

        menu.addItem(.separator())
        let undoItem = NSMenuItem(
            title: "Undo Last Dictation", action: #selector(undoLastDictation), keyEquivalent: "")
        undoItem.target = self
        menu.addItem(undoItem)
        let historyItem = NSMenuItem(
            title: "History\u{2026}", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quit = NSMenuItem(title: "Quit FreeSpeech", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ActivationMode(rawValue: raw) else { return }
        settings.mode = mode
        Log.info("settings changed: mode=\(mode.rawValue)")
        onSettingsChanged?()
    }

    @objc private func selectMicInput(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        // A single chosen device becomes the whole priority list; empty means system default.
        settings.micPriority = uid.isEmpty ? [] : [uid]
        Log.info("settings changed: micInput=\(uid.isEmpty ? "systemDefault" : uid)")
        onSettingsChanged?()
    }

    @objc private func selectPostProcessing(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PostProcessingMode(rawValue: raw) else { return }
        settings.postProcessing = mode
        Log.info("settings changed: postProcessing=\(mode.rawValue)")
        onSettingsChanged?()
    }

    @objc private func toggleSplitSpeakers() {
        settings.splitSpeakersEnabled.toggle()
        Log.info("settings changed: splitSpeakers=\(settings.splitSpeakersEnabled)")
        onSettingsChanged?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openHistory() {
        onOpenHistory?()
    }

    @objc private func undoLastDictation() {
        onUndoLastDictation?()
    }

    @objc private func quitApp() {
        Log.info("quit requested from menu")
        NSApp.terminate(nil)
    }
}
