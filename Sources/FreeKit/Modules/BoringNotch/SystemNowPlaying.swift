import AppKit
import FreeKitCore

// Since macOS 15.4, MediaRemote.framework only answers processes whose bundle identifier
// starts with "com.apple." — calling it in-process (dlopen/CFBundle) from this app now
// silently returns nothing. /usr/bin/osascript is one such Apple-signed process, so the
// same AppleScriptObjC bridge that used to run in-process is shelled out to it instead.
// This is the same workaround boring.notch, Music Presence, and other now-playing tools
// adopted after the restriction landed (see github.com/ungive/mediaremote-adapter).
// Verified live against Spotify/Apple Music on macOS 26 before wiring this in.
enum SystemNowPlaying {
    struct Info {
        let appName: String
        let title: String
        let artist: String
        let duration: Double
        let elapsed: Double
        /// True when the OS's now-playing timestamp is fresh — it's kept continuously
        /// up to date while media plays and goes stale the instant it's paused, which is
        /// a more reliable playing/paused signal than the (inconsistently reported) rate key.
        let playing: Bool
    }

    // `on run` returns "" for "nothing playing"; fields are "|||"-joined like the rest of
    // this module's AppleScript reads. `safeText` guards every optional key: some apps
    // (podcasts, browsers) omit artist/duration/timestamp entirely, and coercing a missing
    // value with `as text` throws and would otherwise abort the whole script.
    private static let script = """
    use framework "AppKit"
    use scripting additions
    on safeText(v)
        if v is missing value then return ""
        try
            return (v as text)
        on error
            return ""
        end try
    end safeText
    on run
        set MediaRemote to current application's NSBundle's bundleWithPath:"/System/Library/PrivateFrameworks/MediaRemote.framework/"
        MediaRemote's load()
        set req to current application's NSClassFromString("MRNowPlayingRequest")
        set nowItem to req's localNowPlayingItem()
        if nowItem is missing value then return ""
        set infoDict to nowItem's nowPlayingInfo()
        if infoDict is missing value then return ""
        set appName to safeText((req's localNowPlayingPlayerPath())'s |client|()'s displayName())
        set theTitle to safeText(infoDict's valueForKey:"kMRMediaRemoteNowPlayingInfoTitle")
        if theTitle is "" then return ""
        set theArtist to safeText(infoDict's valueForKey:"kMRMediaRemoteNowPlayingInfoArtist")
        set theDuration to safeText(infoDict's valueForKey:"kMRMediaRemoteNowPlayingInfoDuration")
        set theElapsed to safeText(infoDict's valueForKey:"kMRMediaRemoteNowPlayingInfoElapsedTime")
        set theTimestamp to ""
        set tsObj to infoDict's valueForKey:"kMRMediaRemoteNowPlayingInfoTimestamp"
        if tsObj is not missing value then
            try
                set theTimestamp to ((tsObj's timeIntervalSince1970()) as text)
            end try
        end if
        return appName & "|||" & theTitle & "|||" & theArtist & "|||" & theDuration & "|||" & theElapsed & "|||" & theTimestamp
    end run
    """

    /// Blocking; call off the main thread. ~150-250ms per call (a fresh osascript process),
    /// fine at the existing 2s poll cadence.
    static func fetch() -> Info? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            Log.error("notch media: failed to launch osascript for system-wide now playing: \(error.localizedDescription)")
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let data = try? outPipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "|||")
        guard parts.count == 6, !parts[1].isEmpty else { return nil }
        let timestamp = Double(parts[5]) ?? 0
        let freshness = abs(Date().timeIntervalSince1970 - timestamp)
        return Info(appName: parts[0], title: parts[1], artist: parts[2],
                    duration: Double(parts[3]) ?? 0, elapsed: Double(parts[4]) ?? 0,
                    playing: timestamp > 0 && freshness < 4)
    }
}

// Universal transport control via simulated hardware media keys (NX_KEYTYPE_*), posted as
// NSSystemDefined events. Works for any app that responds to a keyboard's media keys —
// unlike MediaRemote's own command channel, this isn't gated by process identity.
enum MediaKey: Int {
    case playPause = 16  // NX_KEYTYPE_PLAY
    case next = 17       // NX_KEYTYPE_NEXT
    case previous = 18   // NX_KEYTYPE_PREVIOUS

    func post() {
        postEvent(keyDown: true)
        postEvent(keyDown: false)
    }

    private func postEvent(keyDown: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: keyDown ? 0xa00 : 0xb00)
        let data1 = (rawValue << 16) | ((keyDown ? 0xa : 0xb) << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
