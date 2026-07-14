import XCTest
@testable import FreeKitCore

final class DictationStateMachineTests: XCTestCase {
    func testPushToTalkHappyPath() {
        var m = DictationStateMachine()
        XCTAssertEqual(m.handle(.hotkeyDown(.microphone), mode: .pushToTalk), .startRecording(.microphone))
        XCTAssertEqual(m.state, .recording(.microphone))
        XCTAssertEqual(m.handle(.hotkeyUp(.microphone), mode: .pushToTalk), .stopAndTranscribe)
        XCTAssertEqual(m.state, .transcribing)
        XCTAssertEqual(m.handle(.transcriptionSucceeded, mode: .pushToTalk), .becameIdle)
        XCTAssertEqual(m.state, .idle)
    }

    func testToggleHappyPath() {
        var m = DictationStateMachine()
        XCTAssertEqual(m.handle(.hotkeyDown(.microphone), mode: .toggle), .startRecording(.microphone))
        XCTAssertEqual(m.handle(.hotkeyUp(.microphone), mode: .toggle), .none)
        XCTAssertEqual(m.state, .recording(.microphone))
        XCTAssertEqual(m.handle(.hotkeyDown(.microphone), mode: .toggle), .stopAndTranscribe)
        XCTAssertEqual(m.state, .transcribing)
    }

    func testPressesDuringTranscribingAreIgnored() {
        var m = DictationStateMachine()
        _ = m.handle(.hotkeyDown(.microphone), mode: .pushToTalk)
        _ = m.handle(.hotkeyUp(.microphone), mode: .pushToTalk)
        XCTAssertEqual(m.handle(.hotkeyDown(.microphone), mode: .pushToTalk), .none)
        XCTAssertEqual(m.handle(.hotkeyUp(.microphone), mode: .pushToTalk), .none)
        XCTAssertEqual(m.state, .transcribing)
    }

    func testDoubleDownIsIgnoredInPushToTalk() {
        var m = DictationStateMachine()
        _ = m.handle(.hotkeyDown(.microphone), mode: .pushToTalk)
        XCTAssertEqual(m.handle(.hotkeyDown(.microphone), mode: .pushToTalk), .none)
        XCTAssertEqual(m.state, .recording(.microphone))
    }

    func testStrayUpInIdleIsIgnored() {
        var m = DictationStateMachine()
        XCTAssertEqual(m.handle(.hotkeyUp(.microphone), mode: .pushToTalk), .none)
        XCTAssertEqual(m.state, .idle)
    }

    func testMaxDurationStopsRecording() {
        var m = DictationStateMachine()
        _ = m.handle(.hotkeyDown(.microphone), mode: .pushToTalk)
        XCTAssertEqual(m.handle(.recordingTimedOut, mode: .pushToTalk), .stopAndTranscribe)
        XCTAssertEqual(m.state, .transcribing)
    }

    func testTranscriptionFailureSurfacesErrorThenRecovers() {
        var m = DictationStateMachine()
        _ = m.handle(.hotkeyDown(.microphone), mode: .pushToTalk)
        _ = m.handle(.hotkeyUp(.microphone), mode: .pushToTalk)
        XCTAssertEqual(
            m.handle(.transcriptionFailed("model load failed"), mode: .pushToTalk),
            .showError("model load failed"))
        XCTAssertEqual(m.state, .error("model load failed"))
        XCTAssertEqual(m.handle(.errorDismissed, mode: .pushToTalk), .becameIdle)
        XCTAssertEqual(m.state, .idle)
    }

    func testHotkeyDownInErrorStateStartsFreshRecording() {
        var m = DictationStateMachine()
        _ = m.handle(.hotkeyDown(.microphone), mode: .pushToTalk)
        _ = m.handle(.recordingFailed("audio device init failed"), mode: .pushToTalk)
        XCTAssertEqual(m.state, .error("audio device init failed"))
        XCTAssertEqual(m.handle(.hotkeyDown(.microphone), mode: .pushToTalk), .startRecording(.microphone))
        XCTAssertEqual(m.state, .recording(.microphone))
    }

    func testSystemAudioHappyPath() {
        var m = DictationStateMachine()
        XCTAssertEqual(
            m.handle(.hotkeyDown(.systemAudio), mode: .pushToTalk),
            .startRecording(.systemAudio))
        XCTAssertEqual(m.state, .recording(.systemAudio))
        XCTAssertEqual(m.handle(.hotkeyUp(.systemAudio), mode: .pushToTalk), .stopAndTranscribe)
    }

    func testOtherSourceCannotStopARecording() {
        var m = DictationStateMachine()
        _ = m.handle(.hotkeyDown(.microphone), mode: .pushToTalk)
        // Releasing (or pressing) the system-audio hotkey must not cut the mic take.
        XCTAssertEqual(m.handle(.hotkeyUp(.systemAudio), mode: .pushToTalk), .none)
        XCTAssertEqual(m.handle(.hotkeyDown(.systemAudio), mode: .pushToTalk), .none)
        XCTAssertEqual(m.state, .recording(.microphone))
        XCTAssertEqual(m.handle(.hotkeyUp(.microphone), mode: .pushToTalk), .stopAndTranscribe)
    }

    func testOtherSourceCannotStopToggleRecording() {
        var m = DictationStateMachine()
        _ = m.handle(.hotkeyDown(.systemAudio), mode: .toggle)
        XCTAssertEqual(m.handle(.hotkeyDown(.microphone), mode: .toggle), .none)
        XCTAssertEqual(m.state, .recording(.systemAudio))
        XCTAssertEqual(m.handle(.hotkeyDown(.systemAudio), mode: .toggle), .stopAndTranscribe)
    }

    func testRecordingFailureAbortsToError() {
        var m = DictationStateMachine()
        _ = m.handle(.hotkeyDown(.microphone), mode: .pushToTalk)
        XCTAssertEqual(
            m.handle(.recordingFailed("no input device"), mode: .pushToTalk),
            .abortRecording("no input device"))
        XCTAssertEqual(m.state, .error("no input device"))
    }
}
