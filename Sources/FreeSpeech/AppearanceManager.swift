import AppKit
import Combine
import SwiftUI

enum AppearanceGradientDirection: String, CaseIterable, Identifiable {
    case vertical = "Vertical"
    case horizontal = "Horizontal"
    case diagonal = "Diagonal"

    var id: String { rawValue }

    var points: (start: UnitPoint, end: UnitPoint) {
        switch self {
        case .vertical: return (.top, .bottom)
        case .horizontal: return (.leading, .trailing)
        case .diagonal: return (.topLeading, .bottomTrailing)
        }
    }
}

enum AppearanceDepth: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case soft = "Soft"
    case layered = "Layered"

    var id: String { rawValue }
}

enum AppearanceCornerStyle: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case balanced = "Balanced"
    case rounded = "Rounded"

    var id: String { rawValue }

    var controlRadius: CGFloat {
        switch self {
        case .compact: return 7
        case .balanced: return 14
        case .rounded: return 19
        }
    }

    var cardRadius: CGFloat {
        switch self {
        case .compact: return 9
        case .balanced: return 20
        case .rounded: return 26
        }
    }
}

enum AppearanceDensity: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case comfortable = "Comfortable"
    case roomy = "Roomy"

    var id: String { rawValue }

    var cardPadding: CGFloat {
        switch self {
        case .compact: return 10
        case .comfortable: return 14
        case .roomy: return 18
        }
    }

    var contentSpacing: CGFloat {
        switch self {
        case .compact: return 8
        case .comfortable: return 12
        case .roomy: return 16
        }
    }
}

enum SuiteMenuIcon: String, CaseIterable, Identifiable {
    case grid = "Grid"
    case toolkit = "Toolkit"
    case spark = "Spark"
    case command = "Command"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .toolkit: return "wrench.and.screwdriver"
        case .spark: return "sparkles"
        case .command: return "command"
        }
    }
}

final class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()

    private enum Key {
        static let accent = "appearance.accent"
        static let gradientEnabled = "appearance.gradient.enabled"
        static let gradientStart = "appearance.gradient.start"
        static let gradientEnd = "appearance.gradient.end"
        static let gradientDirection = "appearance.gradient.direction"
        static let gradientIntensity = "appearance.gradient.intensity"
        static let depth = "appearance.depth"
        static let corners = "appearance.corners"
        static let density = "appearance.density"
        static let suiteMenuIcon = "appearance.menu.icon"
        static let suiteMenuQuickTools = "appearance.menu.quickTools"
    }

    static let defaultAccentHex = "FF453A"
    static let defaultGradientStartHex = "271518"
    static let defaultGradientEndHex = "10141C"

    private let defaults: UserDefaults

    @Published var accentHex: String { didSet { persist(accentHex, forKey: Key.accent) } }
    @Published var gradientEnabled: Bool { didSet { persist(gradientEnabled, forKey: Key.gradientEnabled) } }
    @Published var gradientStartHex: String { didSet { persist(gradientStartHex, forKey: Key.gradientStart) } }
    @Published var gradientEndHex: String { didSet { persist(gradientEndHex, forKey: Key.gradientEnd) } }
    @Published var gradientDirection: AppearanceGradientDirection {
        didSet { persist(gradientDirection.rawValue, forKey: Key.gradientDirection) }
    }
    @Published var gradientIntensity: Double {
        didSet { persist(gradientIntensity, forKey: Key.gradientIntensity) }
    }
    @Published var depth: AppearanceDepth { didSet { persist(depth.rawValue, forKey: Key.depth) } }
    @Published var corners: AppearanceCornerStyle { didSet { persist(corners.rawValue, forKey: Key.corners) } }
    @Published var density: AppearanceDensity { didSet { persist(density.rawValue, forKey: Key.density) } }
    @Published var suiteMenuIcon: SuiteMenuIcon {
        didSet { persist(suiteMenuIcon.rawValue, forKey: Key.suiteMenuIcon) }
    }
    @Published var suiteMenuQuickTools: Bool {
        didSet { persist(suiteMenuQuickTools, forKey: Key.suiteMenuQuickTools) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accentHex = defaults.string(forKey: Key.accent) ?? Self.defaultAccentHex
        gradientEnabled = defaults.object(forKey: Key.gradientEnabled) as? Bool ?? false
        gradientStartHex = defaults.string(forKey: Key.gradientStart) ?? Self.defaultGradientStartHex
        gradientEndHex = defaults.string(forKey: Key.gradientEnd) ?? Self.defaultGradientEndHex
        gradientDirection = AppearanceGradientDirection(
            rawValue: defaults.string(forKey: Key.gradientDirection) ?? "") ?? .diagonal
        gradientIntensity = defaults.object(forKey: Key.gradientIntensity) as? Double ?? 0.42
        depth = AppearanceDepth(rawValue: defaults.string(forKey: Key.depth) ?? "") ?? .soft
        corners = AppearanceCornerStyle(rawValue: defaults.string(forKey: Key.corners) ?? "") ?? .balanced
        density = AppearanceDensity(rawValue: defaults.string(forKey: Key.density) ?? "") ?? .comfortable
        suiteMenuIcon = SuiteMenuIcon(rawValue: defaults.string(forKey: Key.suiteMenuIcon) ?? "") ?? .grid
        suiteMenuQuickTools = defaults.object(forKey: Key.suiteMenuQuickTools) as? Bool ?? true
    }

    var accentColor: NSColor { NSColor(hex: accentHex) ?? NSColor.systemRed }
    var accentDimColor: NSColor { accentColor.blended(withFraction: 0.22, of: .black) ?? accentColor }
    var gradientStartColor: Color { Color(nsColor: NSColor(hex: gradientStartHex) ?? DS.ink0) }
    var gradientEndColor: Color { Color(nsColor: NSColor(hex: gradientEndHex) ?? DS.ink0) }

    func reset() {
        accentHex = Self.defaultAccentHex
        gradientEnabled = false
        gradientStartHex = Self.defaultGradientStartHex
        gradientEndHex = Self.defaultGradientEndHex
        gradientDirection = .diagonal
        gradientIntensity = 0.42
        depth = .soft
        corners = .balanced
        density = .comfortable
        suiteMenuIcon = .grid
        suiteMenuQuickTools = true
    }

    private func persist(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

struct AppearanceBackground: View {
    @ObservedObject private var appearance = AppearanceManager.shared

    var body: some View {
        ZStack {
            Color.dsInk0
            if appearance.gradientEnabled {
                let points = appearance.gradientDirection.points
                LinearGradient(
                    colors: [
                        appearance.gradientStartColor.opacity(appearance.gradientIntensity),
                        appearance.gradientEndColor.opacity(appearance.gradientIntensity),
                    ],
                    startPoint: points.start,
                    endPoint: points.end)
            }
        }
        .ignoresSafeArea()
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    var hexRGB: String {
        guard let rgb = usingColorSpace(.sRGB) else { return AppearanceManager.defaultAccentHex }
        return String(
            format: "%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255)))
    }
}
