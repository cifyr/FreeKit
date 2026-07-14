import AVFoundation
import ApplicationServices
import AppKit
import FreeKitCore

enum Permissions {
    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func microphoneDenied() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }

    static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.info("microphone permission status: \(status.rawValue)")
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("microphone permission request result: \(granted)")
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static func cameraAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestCamera(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        Log.info("camera permission status: \(status.rawValue)")
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Log.info("camera permission request result: \(granted)")
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static func openCameraSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
        NSWorkspace.shared.open(url)
    }

    static func accessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptIfNeeded]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        Log.info("accessibility trusted: \(trusted)")
        return trusted
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    // Lazy: only the system-audio mode needs this, so it is checked (and the
    // system prompt triggered) on first use rather than at launch.
    static func screenRecordingAuthorized(requestIfNeeded: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        Log.info("screen recording permission missing")
        if requestIfNeeded {
            let granted = CGRequestScreenCaptureAccess()
            Log.info("screen recording permission request result: \(granted)")
            return granted
        }
        return false
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
