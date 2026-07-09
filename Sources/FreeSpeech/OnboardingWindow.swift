import AppKit
import SwiftUI
import FreeSpeechCore

// First-run guided setup: welcome, permissions, hotkeys, live practice, keywords, done.
// The practice step is a real text box — dictation inserts into it through the normal
// pipeline, so what the user sees is exactly the real behavior (nothing is "trained").
final class OnboardingStore: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, permissions, hotkey, practice, keywords, done
    }
    enum CaptureTarget { case mic, system }

    private let settings: FreeSpeechCore.Settings
    private let deps: OnboardingDeps
    private let shortcutCapture = ShortcutCapture()
    private var statusTimer: Timer?

    @Published var step: Step = .welcome
    @Published var micGranted = false
    @Published var accessibilityGranted = false
    @Published var hotkey: HotkeyPreset
    @Published var systemHotkey: HotkeyPreset
    @Published var capturing: CaptureTarget?
    @Published var vocabularyHint: String
    @Published var practiceText = ""
    // Set by the app while the model self-downloads on first run; nil when ready.
    @Published var modelStatus: String?

    let activationMode: ActivationMode

    init(settings: FreeSpeechCore.Settings, deps: OnboardingDeps) {
        self.settings = settings
        self.deps = deps
        self.hotkey = settings.hotkey
        self.systemHotkey = settings.systemAudioHotkey
        self.vocabularyHint = settings.vocabularyHint
        self.activationMode = settings.mode
        refreshPermissions()
    }

    var stepIndex: Int { step.rawValue + 1 }
    var stepCount: Int { Step.allCases.count }
    var canGoBack: Bool { step != .welcome }
    var permissionsSatisfied: Bool { micGranted && accessibilityGranted }

    // Push-to-talk holds; toggle presses twice. Instructions adapt to the chosen mode.
    func actionVerb(_ keyName: String) -> String {
        activationMode == .pushToTalk
            ? "Hold \(keyName) and speak, then release to insert."
            : "Press \(keyName) to start, speak, then press it again to stop."
    }

    func next() {
        guard let nextStep = Step(rawValue: step.rawValue + 1) else { finish(); return }
        leave(step); step = nextStep; enter(nextStep)
    }
    func back() {
        guard let prevStep = Step(rawValue: step.rawValue - 1) else { return }
        leave(step); step = prevStep; enter(prevStep)
    }

    private func enter(_ step: Step) {
        if step == .permissions { startStatusPolling() }
    }
    private func leave(_ step: Step) {
        if step == .permissions { stopStatusPolling() }
        cancelRecord()
    }

    // MARK: Permissions

    func requestMic() { deps.requestMicrophone { [weak self] _ in self?.refreshPermissions() } }
    func requestAccessibility() { _ = deps.requestAccessibility(); refreshPermissions() }

    private func refreshPermissions() {
        micGranted = deps.microphoneAuthorized()
        let ax = deps.accessibilityTrusted()
        if ax && !accessibilityGranted { deps.installHotkey() }  // enable practice once trusted
        accessibilityGranted = ax
    }
    private func startStatusPolling() {
        stopStatusPolling()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
    }
    private func stopStatusPolling() { statusTimer?.invalidate(); statusTimer = nil }

    // MARK: Hotkeys

    func chooseHotkey(_ preset: HotkeyPreset, for target: CaptureTarget) {
        cancelRecord()
        apply(preset, to: target)
    }

    func recordHotkey(_ target: CaptureTarget) {
        capturing = target
        shortcutCapture.begin { [weak self] preset in
            guard let self else { return }
            self.apply(preset, to: target)
            self.capturing = nil
        }
    }

    func cancelRecord() {
        shortcutCapture.end()
        capturing = nil
    }

    private func apply(_ preset: HotkeyPreset, to target: CaptureTarget) {
        switch target {
        case .mic: hotkey = preset; settings.hotkey = preset
        case .system: systemHotkey = preset; settings.systemAudioHotkey = preset
        }
        deps.installHotkey()
    }

    // MARK: Keywords / finish

    func saveKeywords() { settings.vocabularyHint = vocabularyHint }

    func finish() {
        saveKeywords()
        stopStatusPolling()
        cancelRecord()
        settings.hasCompletedOnboarding = true
        Log.info("onboarding completed")
        deps.onFinished()
    }
    func skipAll() { finish() }
}

// The app-side capabilities onboarding needs, injected so the store stays decoupled.
struct OnboardingDeps {
    var microphoneAuthorized: () -> Bool
    var requestMicrophone: (@escaping (Bool) -> Void) -> Void
    var accessibilityTrusted: () -> Bool
    var requestAccessibility: () -> Bool
    var installHotkey: () -> Void
    var beginPractice: (@escaping (String?) -> Void) -> Void
    var endPractice: () -> Void
    var onFinished: () -> Void
}

struct OnboardingView: View {
    @ObservedObject var store: OnboardingStore
    @FocusState private var practiceFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progressHeader
            if let status = store.modelStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Color.dsAccent)
                    Text(status.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).kerning(1)
                        .foregroundStyle(Color.dsMuted)
                    Spacer()
                }
                .padding(.horizontal, 28).padding(.vertical, 8)
                .background(Color.dsInk1)
            }
            ScrollView {
                content
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 520, height: 600)
        .background(Color.dsInk0)
        .onChange(of: store.step) { _, newStep in
            practiceFocused = (newStep == .practice)
        }
    }

    @ViewBuilder private var content: some View {
        switch store.step {
        case .welcome: welcome
        case .permissions: permissions
        case .hotkey: hotkeyStep
        case .practice: practice
        case .keywords: keywords
        case .done: done
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            bigTitle("Welcome to FreeSpeech")
            body("FreeSpeech turns your voice into text in any app — fully on your Mac, nothing sent to the cloud. Hold a hotkey, speak, and the words appear wherever your cursor is.")
            body("This quick setup grants two permissions, sets your two hotkeys, and lets you try it once. Takes about a minute.")
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            bigTitle("Grant two permissions")
            body("FreeSpeech needs these to hear you and to type for you. Both are checked locally by macOS.")
            permissionRow(name: "Microphone", granted: store.micGranted,
                          detail: "To capture your speech.", action: store.requestMic)
            permissionRow(name: "Accessibility", granted: store.accessibilityGranted,
                          detail: "To insert text into the app you're using, via the global hotkey.",
                          action: store.requestAccessibility)
            if !store.permissionsSatisfied {
                body("Grant both to continue. Accessibility opens System Settings — flip FreeSpeech on, and this updates automatically.")
                    .foregroundStyle(Color.dsFaint)
            }
        }
    }

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            bigTitle("Pick your two hotkeys")
            body("FreeSpeech listens to two sources, each on its own hotkey. Pick a preset or record any key, combo, or bare modifier. \(modeNote)")
            hotkeyPicker(
                title: "Voice in — your microphone",
                detail: "Transcribes what you say into the focused app. This is normal dictation.",
                current: store.hotkey, target: .mic)
            hotkeyPicker(
                title: "Audio out — what your Mac plays",
                detail: "Transcribes system audio — the other side of a Zoom call or a video. Uses Screen Recording permission on first use.",
                current: store.systemHotkey, target: .system)
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 14) {
            bigTitle("Try it out")
            if !store.permissionsSatisfied {
                body("Grant Microphone and Accessibility first (go back a step) to try live dictation. You can also skip this.")
                    .foregroundStyle(Color.dsFaint)
            } else {
                body("Click the box below, then \(store.actionVerb(store.hotkey.displayName)) Say anything — it appears here exactly as it would in any app.")
                TextEditor(text: $store.practiceText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Color.dsPaper)
                    .focused($practiceFocused)
                    .padding(10)
                    .frame(height: 150)
                    .background(Color.dsInk2, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                        .strokeBorder(practiceFocused ? Color.dsAccent : Color.dsLine, lineWidth: 1))
                HStack {
                    body("Not hearing you well? Check your input device and model in Settings.")
                        .foregroundStyle(Color.dsFaint)
                    Spacer()
                    if !store.practiceText.isEmpty {
                        Button("Clear") { store.practiceText = "" }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
    }

    private var keywords: some View {
        VStack(alignment: .leading, spacing: 14) {
            bigTitle("Teach it your words")
            body("Names, jargon, and product names you say often. FreeSpeech uses these to transcribe them correctly — e.g. proper names or tools like \u{201C}Claude Code\u{201D}.")
            TextEditor(text: $store.vocabularyHint)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .foregroundStyle(Color.dsPaper)
                .padding(10)
                .frame(height: 96)
                .background(Color.dsInk2, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                    .strokeBorder(Color.dsLine, lineWidth: 1))
            body("You can edit this anytime in Settings > Vocabulary.").foregroundStyle(Color.dsFaint)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            bigTitle("You're all set")
            body("\(store.actionVerb(store.hotkey.displayName)) anywhere to dictate your voice. \(store.actionVerb(store.systemHotkey.displayName)) to transcribe what your Mac is playing.")
            body("FreeSpeech lives in your menu bar — open it anytime for settings and models. Everything runs on-device.")
        }
    }

    // MARK: Hotkey picker

    private func hotkeyPicker(title: String, detail: String, current: HotkeyPreset, target: OnboardingStore.CaptureTarget) -> some View {
        let capturing = store.capturing == target
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dsPaper)
            Text(detail).font(.system(size: 11)).foregroundStyle(Color.dsMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(HotkeyPreset.all) { preset in
                    chip(preset.displayName, selected: current.id == preset.id && !capturing) {
                        store.chooseHotkey(preset, for: target)
                    }
                }
            }
            HStack(spacing: 10) {
                Text(capturing ? "PRESS KEYS\u{2026}" : (current.id == "custom" ? "CUSTOM: \(current.displayName.uppercased())" : "OR RECORD A CUSTOM ONE"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(capturing || current.id == "custom" ? Color.dsAccent : Color.dsMuted)
                Spacer()
                Button(capturing ? "Cancel" : "Record") {
                    capturing ? store.cancelRecord() : store.recordHotkey(target)
                }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsInk1, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
            .strokeBorder(capturing ? Color.dsAccent : Color.dsLine, lineWidth: 1))
    }

    private var modeNote: String {
        store.activationMode == .pushToTalk
            ? "You're in push-to-talk: hold a hotkey to talk, release to insert."
            : "You're in toggle mode: press once to start, again to stop."
    }

    // MARK: Chrome

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FREESPEECH SETUP")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).kerning(1.2)
                    .foregroundStyle(Color.dsAccent)
                Spacer()
                Text("STEP \(store.stepIndex) / \(store.stepCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).kerning(1.2)
                    .foregroundStyle(Color.dsMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.dsInk2)
                    Capsule().fill(Color.dsAccent)
                        .frame(width: geo.size.width * CGFloat(store.stepIndex) / CGFloat(store.stepCount))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 28).padding(.top, 22)
    }

    private var footer: some View {
        HStack {
            if store.canGoBack {
                Button("Back") { store.back() }.buttonStyle(GhostButtonStyle())
            }
            Button("Skip setup") { store.skipAll() }.buttonStyle(GhostButtonStyle())
            Spacer()
            Button(action: { store.next() }) {
                Text(store.step == .done ? "Start dictating" : "Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dsInk0)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(primaryEnabled ? Color.dsAccent : Color.dsInk3,
                               in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!primaryEnabled)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .background(Color.dsInk1)
        .overlay(Rectangle().fill(Color.dsLine).frame(height: 1), alignment: .top)
    }

    // Permissions is the only hard gate; everything else is skippable.
    private var primaryEnabled: Bool {
        store.step != .permissions || store.permissionsSatisfied
    }

    private func permissionRow(name: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.dsAccent : Color.dsFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dsPaper)
                Text(detail).font(.system(size: 11)).foregroundStyle(Color.dsMuted)
            }
            Spacer()
            if granted {
                Text("GRANTED")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).kerning(1)
                    .foregroundStyle(Color.dsAccent)
            } else {
                Button("Grant", action: action).buttonStyle(GhostButtonStyle())
            }
        }
        .padding(12)
        .background(Color.dsInk1, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
            .strokeBorder(Color.dsLine, lineWidth: 1))
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.dsAccent : Color.dsPaper)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.dsInk2, in: Capsule())
                .overlay(Capsule().strokeBorder(
                    selected ? Color.dsAccent.opacity(0.6) : Color.dsLine, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func bigTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 24, weight: .heavy)).foregroundStyle(Color.dsPaper)
    }
    private func body(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Color.dsMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

final class OnboardingWindowController {
    private var window: NSWindow?
    private let makeStore: (@escaping () -> Void) -> OnboardingStore

    // makeStore receives the "close the window" action to wire into the store's onFinished.
    init(makeStore: @escaping (@escaping () -> Void) -> OnboardingStore) {
        self.makeStore = makeStore
    }

    func show() {
        if window == nil {
            let store = makeStore { [weak self] in self?.close() }
            let hosting = NSHostingController(rootView: OnboardingView(store: store))
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = DS.ink0
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("onboarding window opened")
    }

    func close() {
        window?.close()
        window = nil
    }
}
