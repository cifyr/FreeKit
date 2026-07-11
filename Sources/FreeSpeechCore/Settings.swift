import Foundation

// Mirrors the CGEventFlags bits we care about, so Core stays AppKit-free.
public struct HotkeyModifiers: OptionSet, Equatable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let shift = HotkeyModifiers(rawValue: 0x20000)      // CGEventFlags.maskShift
    public static let control = HotkeyModifiers(rawValue: 0x40000)    // .maskControl
    public static let option = HotkeyModifiers(rawValue: 0x80000)     // .maskAlternate
    public static let command = HotkeyModifiers(rawValue: 0x100000)   // .maskCommand
    public static let fn = HotkeyModifiers(rawValue: 0x800000)        // .maskSecondaryFn

    public static let all: HotkeyModifiers = [.shift, .control, .option, .command, .fn]

    public static let hyper: HotkeyModifiers = [.control, .option, .shift, .command]

    // Apple's canonical display order: Control, Option, Shift, Command.
    // All four together collapse to the community hyper-key glyph — that combo
    // only ever comes from a hyper-style remap, and four stacked symbols read
    // as noise next to one key name.
    public var symbols: String {
        if contains(Self.hyper) {
            return contains(.fn) ? "\u{2726}fn" : "\u{2726}"
        }
        var s = ""
        if contains(.control) { s += "\u{2303}" }
        if contains(.option) { s += "\u{2325}" }
        if contains(.shift) { s += "\u{21E7}" }
        if contains(.command) { s += "\u{2318}" }
        if contains(.fn) { s += "fn" }
        return s
    }
}

public struct HotkeyPreset: Equatable, Identifiable {
    public enum Kind: String { case modifier, key }
    public let id: String
    public let displayName: String
    public let keyCode: Int64
    public let kind: Kind
    public let modifiers: HotkeyModifiers

    public init(id: String, displayName: String, keyCode: Int64, kind: Kind,
                modifiers: HotkeyModifiers = []) {
        self.id = id
        self.displayName = displayName
        self.keyCode = keyCode
        self.kind = kind
        self.modifiers = modifiers
    }

    // Right Option default: rarely used alone, never conflicts with app shortcuts,
    // and a modifier key allows true push-to-talk hold semantics.
    public static let rightOption = HotkeyPreset(
        id: "rightOption", displayName: "Right Option (hold)", keyCode: 61, kind: .modifier)
    public static let rightCommand = HotkeyPreset(
        id: "rightCommand", displayName: "Right Command (hold)", keyCode: 54, kind: .modifier)
    public static let f13 = HotkeyPreset(
        id: "f13", displayName: "F13", keyCode: 105, kind: .key)
    public static let disabled = HotkeyPreset(
        id: "disabled", displayName: "Not Set", keyCode: -1, kind: .key)

    public static let all: [HotkeyPreset] = [.rightOption, .rightCommand, .f13]

    public static func find(id: String) -> HotkeyPreset? {
        if id == disabled.id { return disabled }
        return all.first { $0.id == id }
    }

    // Anything the user records in settings becomes a custom preset: a bare modifier,
    // a plain key, or a full combo like Cmd+K / Cmd+Opt+Space. Hold semantics
    // (push-to-talk) work for all of them.
    public static func custom(keyCode: Int64, modifiers: HotkeyModifiers = []) -> HotkeyPreset {
        let name = modifiers.isEmpty
            ? KeyNames.name(forKeyCode: keyCode)
            : "\(modifiers.symbols) \(KeyNames.name(forKeyCode: keyCode))"
        return HotkeyPreset(
            id: "custom",
            displayName: name,
            keyCode: keyCode,
            kind: modifiers.isEmpty && KeyNames.isModifier(keyCode) ? .modifier : .key,
            modifiers: modifiers)
    }
}

public final class Settings {
    private let defaults: UserDefaults

    private enum Key {
        static let mode = "activationMode"
        static let hotkey = "hotkeyPresetID"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let model = "modelName"
        static let learningEnabled = "learningEnabled"
        static let micPriority = "micPriority"
        static let maxRecordingSeconds = "maxRecordingSeconds"
        static let systemHotkey = "systemHotkeyPresetID"
        static let systemHotkeyKeyCode = "systemHotkeyKeyCode"
        static let systemHotkeyModifiers = "systemHotkeyModifiers"
        static let copyToClipboard = "copyToClipboard"
        static let postProcessing = "postProcessingMode"
        static let tone = "rewriteTone"
        static let vocabularyHint = "vocabularyHint"
        static let screenContextEnabled = "screenContextEnabled"
        static let spokenCommandsEnabled = "spokenCommandsEnabled"
        static let fillerStrippingEnabled = "fillerStrippingEnabled"
        static let customReplacements = "customReplacements"
        static let historyEnabled = "historyEnabled"
        static let language = "transcriptionLanguage"
        static let soundCuesEnabled = "soundCuesEnabled"
        static let hudPosition = "hudPosition"
        static let hudStyle = "hudStyle"
        static let appProfiles = "appPostProcessingProfiles"
        static let splitSpeakers = "splitSpeakersEnabled"
        static let onboarded = "hasCompletedOnboarding"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // Backing-store access for same-module extensions (per-module suite keys in
    // ModuleCatalog.swift) without making `defaults` public.
    func defaultsValue(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    func setDefaultsValue(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public var mode: ActivationMode {
        get { defaults.string(forKey: Key.mode).flatMap(ActivationMode.init) ?? .pushToTalk }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    public var hotkey: HotkeyPreset {
        get {
            let id = defaults.string(forKey: Key.hotkey)
            if id == "custom", defaults.object(forKey: Key.hotkeyKeyCode) != nil {
                return .custom(
                    keyCode: Int64(defaults.integer(forKey: Key.hotkeyKeyCode)),
                    modifiers: HotkeyModifiers(
                        rawValue: UInt64(defaults.integer(forKey: Key.hotkeyModifiers))))
            }
            return id.flatMap(HotkeyPreset.find) ?? .rightOption
        }
        set {
            defaults.set(newValue.id, forKey: Key.hotkey)
            defaults.set(Int(newValue.keyCode), forKey: Key.hotkeyKeyCode)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Key.hotkeyModifiers)
        }
    }

    // Right Command default: mirrors the mic's Right Option (hold to capture),
    // stays off the app-shortcut namespace, and never collides with the mic default.
    public var systemAudioHotkey: HotkeyPreset {
        get {
            let id = defaults.string(forKey: Key.systemHotkey)
            if id == "custom", defaults.object(forKey: Key.systemHotkeyKeyCode) != nil {
                return .custom(
                    keyCode: Int64(defaults.integer(forKey: Key.systemHotkeyKeyCode)),
                    modifiers: HotkeyModifiers(
                        rawValue: UInt64(defaults.integer(forKey: Key.systemHotkeyModifiers))))
            }
            return id.flatMap(HotkeyPreset.find) ?? .rightCommand
        }
        set {
            defaults.set(newValue.id, forKey: Key.systemHotkey)
            defaults.set(Int(newValue.keyCode), forKey: Key.systemHotkeyKeyCode)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Key.systemHotkeyModifiers)
        }
    }

    // Default ON: dictating usually means "I want this text", so keeping it on the
    // clipboard is the useful default; OFF restores the prior clipboard as before.
    public var copyToClipboard: Bool {
        get { defaults.object(forKey: Key.copyToClipboard) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.copyToClipboard) }
    }

    public var learningEnabled: Bool {
        get { defaults.object(forKey: Key.learningEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.learningEnabled) }
    }

    // Default ON: names visible on screen (email threads, chat windows) bias
    // transcription so replies get people's names right. Local-only, toggleable.
    public var screenContextEnabled: Bool {
        get { defaults.object(forKey: Key.screenContextEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.screenContextEnabled) }
    }

    public var spokenCommandsEnabled: Bool {
        get { defaults.object(forKey: Key.spokenCommandsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.spokenCommandsEnabled) }
    }

    public var fillerStrippingEnabled: Bool {
        get { defaults.object(forKey: Key.fillerStrippingEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.fillerStrippingEnabled) }
    }

    // Ordered user dictionary, stored as [from, to] pairs to keep insertion order.
    public var customReplacements: [(from: String, to: String)] {
        get {
            let raw = defaults.array(forKey: Key.customReplacements) as? [[String]] ?? []
            return raw.compactMap { $0.count == 2 ? (from: $0[0], to: $0[1]) : nil }
        }
        set { defaults.set(newValue.map { [$0.from, $0.to] }, forKey: Key.customReplacements) }
    }

    public var historyEnabled: Bool {
        get { defaults.object(forKey: Key.historyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.historyEnabled) }
    }

    // "auto" lets whisper detect the language; .en models are English-only.
    public var language: String {
        get { defaults.string(forKey: Key.language) ?? "en" }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    // The only ggml model with tinydiarize speaker-turn tokens.
    public static let diarizerModelName = "small.en-tdrz"

    // System-audio captures only: breaks the transcript into lines at detected
    // voice changes via a second tinydiarize pass. Costs roughly one extra
    // transcription's latency; text accuracy is unaffected.
    public var splitSpeakersEnabled: Bool {
        get { defaults.object(forKey: Key.splitSpeakers) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.splitSpeakers) }
    }

    public var soundCuesEnabled: Bool {
        get { defaults.object(forKey: Key.soundCuesEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.soundCuesEnabled) }
    }

    public var hudPosition: HUDPosition {
        get { defaults.string(forKey: Key.hudPosition).flatMap(HUDPosition.init) ?? .bottomCenter }
        set { defaults.set(newValue.rawValue, forKey: Key.hudPosition) }
    }

    public var hudStyle: HUDStyle {
        get { defaults.string(forKey: Key.hudStyle).flatMap(HUDStyle.init) ?? .compactBar }
        set { defaults.set(newValue.rawValue, forKey: Key.hudStyle) }
    }

    // Per-app override of the post-processing mode, keyed by bundle identifier.
    public var appProfiles: [String: String] {
        get { defaults.dictionary(forKey: Key.appProfiles) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.appProfiles) }
    }

    public func postProcessing(forApp bundleID: String?) -> PostProcessingMode {
        guard let bundleID,
              let raw = appProfiles[bundleID],
              let mode = PostProcessingMode(rawValue: raw) else { return postProcessing }
        return mode
    }

    // Ordered microphone UIDs; the first one currently connected wins.
    // Empty means "system default input".
    public var micPriority: [String] {
        get { defaults.stringArray(forKey: Key.micPriority) ?? [] }
        set { defaults.set(newValue, forKey: Key.micPriority) }
    }

    public var postProcessing: PostProcessingMode {
        get { defaults.string(forKey: Key.postProcessing).flatMap(PostProcessingMode.init) ?? .cleanup }
        set { defaults.set(newValue.rawValue, forKey: Key.postProcessing) }
    }

    public var tone: RewriteTone {
        get { defaults.string(forKey: Key.tone).flatMap(RewriteTone.init) ?? .professional }
        set { defaults.set(newValue.rawValue, forKey: Key.tone) }
    }

    // Fed to whisper as an initial prompt to bias proper nouns the user actually says.
    // This phrasing benchmarked best: names as a list plus the key term in a sentence.
    public var vocabularyHint: String {
        get {
            defaults.string(forKey: Key.vocabularyHint)
                ?? "Caden Warren, Claude Code, FreeSpeech. My specialty is to use Claude Code on projects."
        }
        set { defaults.set(newValue, forKey: Key.vocabularyHint) }
    }

    // large-v3-turbo-q5_0 won the bench/results.json matrix: best WER (12.9% on the
    // reference clip, with proper nouns right) at ~0.6s per 23s of audio on M4 Max.
    public var modelName: String {
        get { defaults.string(forKey: Key.model) ?? "large-v3-turbo-q5_0" }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    public var maxRecordingSeconds: Double {
        get {
            let v = defaults.double(forKey: Key.maxRecordingSeconds)
            return v > 0 ? v : 60
        }
        set { defaults.set(newValue, forKey: Key.maxRecordingSeconds) }
    }

    // First-run onboarding shows until completed; the menu can reset this to replay it.
    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }
}

// Two sizes from the design handoff; both replace the original 280x44 panel.
public enum HUDStyle: String, CaseIterable {
    case compactBar
    case microCapsule

    public var displayName: String {
        switch self {
        case .compactBar: return "Compact bar"
        case .microCapsule: return "Micro capsule"
        }
    }
}

public enum HUDPosition: String, CaseIterable {
    case bottomCenter
    case topCenter
    case bottomLeft
    case bottomRight

    public var displayName: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .topCenter: return "Top center"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

public enum TranscriptionLanguage {
    // Small curated set; whisper accepts ISO 639-1 codes and "auto".
    public static let options: [(code: String, name: String)] = [
        ("en", "English"), ("auto", "Auto-detect"), ("es", "Spanish"),
        ("fr", "French"), ("de", "German"), ("pt", "Portuguese"),
        ("it", "Italian"), ("hi", "Hindi"), ("ja", "Japanese"),
        ("ko", "Korean"), ("zh", "Chinese"), ("pa", "Punjabi"),
    ]

    public static func name(for code: String) -> String {
        options.first { $0.code == code }?.name ?? code
    }
}

public enum MicPriority {
    // First preferred device that is actually connected; nil means system default.
    public static func pick(priority: [String], connected: [String]) -> String? {
        priority.first { connected.contains($0) }
    }
}

public enum AppPaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeSpeech", isDirectory: true)
    }
    public static var modelsDir: URL {
        appSupport.appendingPathComponent("models", isDirectory: true)
    }
    public static var logFile: URL {
        appSupport.appendingPathComponent("freespeech.log")
    }
    public static func modelFile(named name: String) -> URL {
        modelsDir.appendingPathComponent("ggml-\(name).bin")
    }
    public static var learningFile: URL {
        appSupport.appendingPathComponent("learning.json")
    }
    public static var historyFile: URL {
        appSupport.appendingPathComponent("history.jsonl")
    }
    public static var notesDir: URL {
        appSupport.appendingPathComponent("notes", isDirectory: true)
    }
    public static func installedModels() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        return files.compactMap { f in
            guard f.hasPrefix("ggml-"), f.hasSuffix(".bin") else { return nil }
            return String(f.dropFirst("ggml-".count).dropLast(".bin".count))
        }.sorted()
    }
}
