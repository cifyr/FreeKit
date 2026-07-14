import Foundation

public enum ActivationMode: String, CaseIterable {
    case pushToTalk
    case toggle

    public var displayName: String {
        switch self {
        case .pushToTalk: return "Push to talk (hold)"
        case .toggle: return "Toggle (press twice)"
        }
    }
}

public enum AudioSource: String, Equatable {
    case microphone
    case systemAudio

    public var displayName: String {
        switch self {
        case .microphone: return "microphone"
        case .systemAudio: return "system audio"
        }
    }
}

public enum DictationState: Equatable {
    case idle
    case recording(AudioSource)
    case transcribing
    case error(String)
}

public enum DictationEvent: Equatable {
    case hotkeyDown(AudioSource)
    case hotkeyUp(AudioSource)
    case recordingTimedOut
    case recordingFailed(String)
    case transcriptionSucceeded
    case transcriptionFailed(String)
    case errorDismissed
}

public enum DictationAction: Equatable {
    case startRecording(AudioSource)
    case stopAndTranscribe
    case abortRecording(String)
    case showError(String)
    case becameIdle
    case none
}

// Pure transition logic so double-triggers and mid-transcription presses are
// provably ignored; the app layer executes the returned action.
public struct DictationStateMachine {
    public private(set) var state: DictationState = .idle

    public init() {}

    public mutating func handle(_ event: DictationEvent, mode: ActivationMode) -> DictationAction {
        switch (state, event) {
        case (.idle, .hotkeyDown(let source)), (.error, .hotkeyDown(let source)):
            state = .recording(source)
            return .startRecording(source)

        // Only the source that started the session may stop it: releasing the
        // system-audio hotkey must never cut a microphone recording, and vice versa.
        case (.recording(let active), .hotkeyUp(let source))
            where mode == .pushToTalk && active == source,
             (.recording(let active), .hotkeyDown(let source))
            where mode == .toggle && active == source:
            state = .transcribing
            return .stopAndTranscribe

        case (.recording, .recordingTimedOut):
            state = .transcribing
            return .stopAndTranscribe

        case (.recording, .recordingFailed(let reason)):
            state = .error(reason)
            return .abortRecording(reason)

        case (.transcribing, .transcriptionSucceeded):
            state = .idle
            return .becameIdle

        case (.transcribing, .transcriptionFailed(let reason)):
            state = .error(reason)
            return .showError(reason)

        case (.error, .errorDismissed):
            state = .idle
            return .becameIdle

        // Guards: presses while transcribing, the other source's hotkey during a
        // recording, stray key-ups, repeated downs in push-to-talk, key-ups in
        // toggle mode — all ignored.
        default:
            return .none
        }
    }
}
