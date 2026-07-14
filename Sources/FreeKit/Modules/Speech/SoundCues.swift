import AppKit
import FreeKitCore

// Short system sounds so push-to-talk feels confident without looking at the HUD.
enum SoundCues {
    enum Cue: String {
        case start = "Tink"
        case inserted = "Pop"
        case error = "Basso"
    }

    static func play(_ cue: Cue, enabled: Bool) {
        guard enabled else { return }
        guard let sound = NSSound(named: cue.rawValue) else {
            Log.error("sound cue \(cue.rawValue) not found")
            return
        }
        sound.volume = 0.35
        sound.play()
    }
}
