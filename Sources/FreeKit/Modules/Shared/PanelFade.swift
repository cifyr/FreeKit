import AppKit

// Shared appear/disappear treatment for the suite's floating panels (drop
// zone, shelf, toasts): quick fades routed through the motion grammar so they
// share one duration, one decelerate curve, and the Reduce Motion gate.
extension NSPanel {
    func dsFadeIn(duration: TimeInterval = DS.hudCrossfade) {
        DSMotionAppKit.fadeIn(self, duration: duration)
    }

    func dsFadeOut(duration: TimeInterval = DS.hudCrossfade) {
        DSMotionAppKit.fadeOut(self, duration: duration)
    }
}
