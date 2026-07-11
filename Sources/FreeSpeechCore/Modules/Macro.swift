import Foundation

// One step of a Tap macro. Kept as a Codable enum so macros serialize to JSON
// in settings and the executor stays a dumb interpreter.
public enum MacroStep: Codable, Equatable {
    // x/y nil means "at the cursor".
    case click(button: AutoclickPlan.Button, type: AutoclickPlan.ClickType,
               x: Double?, y: Double?)
    case key(keyCode: Int64, modifiers: UInt64)
    case wait(seconds: Double)

    public var summary: String {
        switch self {
        case .click(let button, let type, let x, let y):
            let kind = type == .double ? "Double-click" : "Click"
            let side = button == .right ? " (right)" : ""
            if let x, let y {
                return "\(kind)\(side) at (\(Int(x)), \(Int(y)))"
            }
            return "\(kind)\(side) at cursor"
        case .key(let keyCode, let modifiers):
            let mods = HotkeyModifiers(rawValue: modifiers).symbols
            let name = KeyNames.name(forKeyCode: keyCode)
            return "Press \(mods.isEmpty ? name : "\(mods) \(name)")"
        case .wait(let seconds):
            return String(format: "Wait %.2gs", seconds)
        }
    }
}

// A recorded sequence plus how to repeat it. Runs = full passes through steps.
public struct Macro: Codable, Equatable {
    public var steps: [MacroStep]
    // 0 = until stopped.
    public var repeatCount: Int
    // Pause between passes.
    public var interval: TimeInterval
    // Pause between steps within a pass.
    public var stepGap: TimeInterval

    public init(steps: [MacroStep] = [], repeatCount: Int = 0,
                interval: TimeInterval = 0.5, stepGap: TimeInterval = 0.05) {
        self.steps = steps
        self.repeatCount = max(0, repeatCount)
        self.interval = max(0, interval)
        self.stepGap = max(0, stepGap)
    }

    public func isComplete(afterRuns runs: Int) -> Bool {
        repeatCount > 0 && runs >= repeatCount
    }

    public func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(json: String) -> Macro? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(Macro.self, from: data)
        } catch {
            Log.error("macro: failed to decode stored macro: \(error)")
            return nil
        }
    }
}
