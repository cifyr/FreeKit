import Foundation
import CoreGraphics

// Pure geometry for the permission-coach popup: where to put a panel relative
// to the System Settings window. AppKit coordinates (origin bottom-left).
public enum CoachPlacement {
    public static let gap: CGFloat = 12
    public static let screenInset: CGFloat = 8

    public struct Position: Equatable {
        public let origin: CGPoint
        // Whether the panel sits below the target window (it flips above when
        // the window is too close to the bottom of the screen).
        public let below: Bool

        public init(origin: CGPoint, below: Bool) {
            self.origin = origin
            self.below = below
        }
    }

    public static func position(
        panelSize: CGSize, targetFrame: CGRect, screenFrame: CGRect
    ) -> Position {
        var x = targetFrame.midX - panelSize.width / 2
        x = max(screenFrame.minX + screenInset,
                min(x, screenFrame.maxX - panelSize.width - screenInset))

        let belowY = targetFrame.minY - gap - panelSize.height
        if belowY >= screenFrame.minY + screenInset {
            return Position(origin: CGPoint(x: x, y: belowY), below: true)
        }
        var aboveY = targetFrame.maxY + gap
        aboveY = min(aboveY, screenFrame.maxY - panelSize.height - screenInset)
        return Position(origin: CGPoint(x: x, y: aboveY), below: false)
    }

    // Fallback when the System Settings window cannot be located: top-center
    // of the screen, where a just-launched app is easy to associate with.
    public static func fallbackOrigin(panelSize: CGSize, screenFrame: CGRect) -> CGPoint {
        CGPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - panelSize.height - 48)
    }
}
