import AppKit
import SwiftUI
import FreeKitCore

// Where the result toast sits on the active screen; composed from a vertical
// edge and a horizontal alignment so the settings UI can offer two short rows.
enum ClopToastLocation: String, CaseIterable, Identifiable {
    case bottomLeft, bottomCenter, bottomRight, topLeft, topCenter, topRight
    var id: String { rawValue }

    enum Align: CaseIterable, Hashable {
        case left, center, right
        var title: String {
            switch self {
            case .left: return "Left"
            case .center: return "Center"
            case .right: return "Right"
            }
        }
    }

    var isBottom: Bool { self == .bottomLeft || self == .bottomCenter || self == .bottomRight }
    var align: Align {
        switch self {
        case .bottomLeft, .topLeft: return .left
        case .bottomCenter, .topCenter: return .center
        case .bottomRight, .topRight: return .right
        }
    }
    static func make(bottom: Bool, align: Align) -> ClopToastLocation {
        switch (bottom, align) {
        case (true, .left): return .bottomLeft
        case (true, .center): return .bottomCenter
        case (true, .right): return .bottomRight
        case (false, .left): return .topLeft
        case (false, .center): return .topCenter
        case (false, .right): return .topRight
        }
    }
    // 20pt inset from the usable edges; bottom sits a little higher so it clears
    // the Dock, matching the original placement.
    func origin(in visible: NSRect, panelSize: NSSize) -> NSPoint {
        let inset: CGFloat = 20
        let x: CGFloat
        switch align {
        case .left: x = visible.minX + inset
        case .center: x = visible.midX - panelSize.width / 2
        case .right: x = visible.maxX - panelSize.width - inset
        }
        let y = isBottom ? visible.minY + 110 : visible.maxY - panelSize.height - inset
        return NSPoint(x: x, y: y)
    }
}

// Floating result readout: every optimization outcome surfaces here for a
// couple of seconds, so "nothing happened" is always distinguishable from
// "left untouched on purpose" without opening a menu. Main thread only.
enum ClopToast {
    private static var panel: NSPanel?
    private static let model = ClopToastModel()
    private static var dismissWork: DispatchWorkItem?

    static func show(_ message: String,
                     duration: TimeInterval = 2.6,
                     location: ClopToastLocation = .bottomCenter) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        model.message = message
        position(panel, location: location)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.dsFadeIn()
        }
        dismissWork?.cancel()
        let work = DispatchWorkItem { panel.dsFadeOut() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, duration), execute: work)
    }

    private static func position(_ panel: NSPanel, location: ClopToastLocation) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(location.origin(in: visible, panelSize: panel.frame.size))
    }

    private static func makePanel() -> NSPanel {
        let size = NSSize(width: 320, height: 44)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: ClopToastView(model: model))
        return panel
    }
}

private final class ClopToastModel: ObservableObject {
    @Published var message = ""
}

private struct ClopToastView: View {
    @ObservedObject var model: ClopToastModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dsAccent)
            Text(model.message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
                .lineLimit(1)
                .truncationMode(.middle)
                // A back-to-back toast reuses the visible panel; crossfade the
                // readout instead of snapping so the byte count settles calmly.
                .dsContentCrossfade(model.message)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color.dsInk1.opacity(0.97)))
        .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
        .padding(4)
    }
}
