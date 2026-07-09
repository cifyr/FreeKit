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

    // Apple's canonical display order: Control, Option, Shift, Command.
    public var symbols: String {
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

    public static let all: [HotkeyPreset] = [.rightOption, .rightCommand, .f13]

    public static func find(id: String) -> HotkeyPreset? {
        all.first { $0.id == id }
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
        static let postProcessing = "postProcessingMode"
        static let tone = "rewriteTone"
        static let vocabularyHint = "vocabularyHint"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    public var learningEnabled: Bool {
        get { defaults.object(forKey: Key.learningEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.learningEnabled) }
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
    public static func installedModels() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        return files.compactMap { f in
            guard f.hasPrefix("ggml-"), f.hasSuffix(".bin") else { return nil }
            return String(f.dropFirst("ggml-".count).dropLast(".bin".count))
        }.sorted()
    }
}
