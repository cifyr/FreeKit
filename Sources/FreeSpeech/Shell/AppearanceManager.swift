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

final class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()

    private enum Key {
        static let gradientDirection = "appearance.gradient.direction"
        static let gradientIntensity = "appearance.gradient.intensity"
        static let density = "appearance.density"
    }

    // Fixed to the reference design: "red is reserved for live and for what
    // is on," so there's no accent picker to contradict that, and the wash
    // is the suite's one signature look rather than a themeable option.
    static let defaultAccentHex = "FF453A"
    static let defaultGradientStartHex = "3B2622"
    static let defaultGradientEndHex = "16202E"

    private let defaults: UserDefaults

    let accentHex: String = AppearanceManager.defaultAccentHex
    let gradientStartHex: String = AppearanceManager.defaultGradientStartHex
    let gradientEndHex: String = AppearanceManager.defaultGradientEndHex
    let depth: AppearanceDepth = .soft
    let corners: AppearanceCornerStyle = .balanced

    // Direction, intensity, and density are the only knobs left in the
    // Appearance tab — everything else about the wash is fixed.
    @Published var gradientDirection: AppearanceGradientDirection {
        didSet { persist(gradientDirection.rawValue, forKey: Key.gradientDirection) }
    }
    @Published var gradientIntensity: Double {
        didSet { persist(gradientIntensity, forKey: Key.gradientIntensity) }
    }
    @Published var density: AppearanceDensity { didSet { persist(density.rawValue, forKey: Key.density) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        gradientDirection = AppearanceGradientDirection(
            rawValue: defaults.string(forKey: Key.gradientDirection) ?? "") ?? .diagonal
        // Reference wash runs at ~0.72; 0.42 read as barely-there in testing.
        gradientIntensity = defaults.object(forKey: Key.gradientIntensity) as? Double ?? 0.62
        density = AppearanceDensity(rawValue: defaults.string(forKey: Key.density) ?? "") ?? .comfortable
    }

    var accentColor: NSColor { NSColor(hex: accentHex) ?? NSColor.systemRed }
    var accentDimColor: NSColor { accentColor.blended(withFraction: 0.22, of: .black) ?? accentColor }
    var gradientStartColor: Color { Color(nsColor: NSColor(hex: gradientStartHex) ?? DS.ink0) }
    var gradientEndColor: Color { Color(nsColor: NSColor(hex: gradientEndHex) ?? DS.ink0) }

    // Shared by DSWashLayer and any custom Shape that needs to fill itself
    // with the wash directly (Shape.fill() overflows its nominal frame
    // correctly for shapes like the settings card's corner blob; a View
    // background clipped to that same shape can't, since clipping can only
    // reveal pixels the view already laid out within its own bounds).
    //
    // A pair of soft radial blobs from opposite corners, not a hard-edged
    // linear band — closer to the reference's own default rendering, and
    // reads as organic/"wavy" with a slow, gradual falloff instead of a
    // mechanically straight diagonal seam. EllipticalGradient's radius
    // fractions are relative to each fill's own bounding box, so both blobs
    // stay correctly proportioned whether they're filling a small popup or
    // the full window — no GeometryReader needed.
    var washPrimary: EllipticalGradient {
        EllipticalGradient(
            colors: [gradientStartColor.opacity(gradientIntensity), .clear],
            center: gradientDirection.points.start,
            startRadiusFraction: 0, endRadiusFraction: 0.85)
    }
    var washSecondary: EllipticalGradient {
        EllipticalGradient(
            colors: [gradientEndColor.opacity(gradientIntensity), .clear],
            center: gradientDirection.points.end,
            startRadiusFraction: 0, endRadiusFraction: 0.85)
    }

    func reset() {
        gradientDirection = .diagonal
        gradientIntensity = 0.62
        density = .comfortable
    }

    private func persist(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

// Pure visual wash + grain, reused two ways: AppearanceBackground wraps it
// with window-drag hit-testing for a real window's content root; module
// popups that float as a card inside Control Center (not a window of their
// own) use this directly, clipped to their own shape, so they carry the same
// signature look without claiming background-drag.
struct DSWashLayer: View {
    @ObservedObject private var appearance = AppearanceManager.shared
    var baseColor: Color = .dsInk0
    // A second translucent pass compounds the blobs' alpha coverage for
    // surfaces that want a richer wash than the shared default — the Notch,
    // whose color is otherwise easy to lose against real hardware black.
    var bold: Bool = false

    var body: some View {
        ZStack {
            baseColor
            appearance.washPrimary
            appearance.washSecondary
            if bold {
                appearance.washPrimary
                appearance.washSecondary
            }
            DSGrainOverlay()
        }
    }
}

struct AppearanceBackground: View {
    var body: some View {
        DSWashLayer()
            .ignoresSafeArea()
            // FreeKit windows no longer use isMovableByWindowBackground (AppKit's
            // background drag fought slider/control gestures and moved the window
            // mid-drag). Instead this shared background IS the drag surface:
            // content in front (text, buttons, sliders) wins hit-testing, so only
            // true empty-background drags move the window.
            .gesture(WindowDragGesture())
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
