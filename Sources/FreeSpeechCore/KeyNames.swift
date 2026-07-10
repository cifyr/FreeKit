import Foundation

// Human-readable names for macOS virtual key codes, for the shortcut recorder UI.
public enum KeyNames {
    public static let modifierKeyCodes: Set<Int64> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    private static let names: [Int64: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "5", 23: "6", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\",
        43: ",", 44: "/", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        54: "Right Command", 55: "Left Command", 56: "Left Shift", 58: "Left Option",
        59: "Left Control", 60: "Right Shift", 61: "Right Option", 62: "Right Control",
        63: "Fn (Globe)",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        118: "F4", 120: "F2", 122: "F1",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
    ]

    public static func name(forKeyCode keyCode: Int64) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    public static func isModifier(_ keyCode: Int64) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }
}
