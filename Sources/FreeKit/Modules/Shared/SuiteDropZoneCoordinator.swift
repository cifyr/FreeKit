import AppKit
import SwiftUI
import FreeKitCore

// Shared floating "drop zone" catcher for Clop and Convert. Both want a panel
// at the same bottom-center spot while the user drags a file anywhere on
// screen, so a single coordinator owns the drag-detection timer and the
// panel: one tool's target shows alone when only it is active, and the panel
// splits into Clop|Convert halves when both are.
final class SuiteDropZoneCoordinator {
    var onClopDrop: (([URL]) -> Void)?
    var onConvertDrop: (([URL]) -> Void)?

    private var panel: NSPanel?
    private var timer: Timer?
    private var lastDragChangeCount: Int
    private(set) var isVisible = false
    private var clopActive = false
    private var convertActive = false

    init() {
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    }

    func setClopActive(_ on: Bool) {
        guard clopActive != on else { return }
        clopActive = on
        updateTimerState()
    }

    func setConvertActive(_ on: Bool) {
        guard convertActive != on else { return }
        convertActive = on
        updateTimerState()
    }

    private func updateTimerState() {
        if clopActive || convertActive {
            startTimerIfNeeded()
        } else {
            stopTimer()
            hide()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        // Only fresh drags count; whatever was already in flight when the
        // first side activated stays uncaught.
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let dragPasteboard = NSPasteboard(name: .drag)
        if dragPasteboard.changeCount != lastDragChangeCount {
            lastDragChangeCount = dragPasteboard.changeCount
            if NSEvent.pressedMouseButtons != 0 {
                show()
            }
        }
        if isVisible, NSEvent.pressedMouseButtons == 0 {
            hide()
        }
    }

    func hide() {
        guard isVisible else { return }
        panel?.dsFadeOut()
        isVisible = false
        Log.info("dropzone: hidden")
    }

    private func show() {
        guard clopActive || convertActive else { return }
        // Rebuilt on every show so a drop-zone toggle flipped mid-session is
        // reflected the next time a drag starts.
        let panel = makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.minY + 48))
        }
        panel.dsFadeIn()
        isVisible = true
        Log.info("dropzone: shown (clop=\(clopActive) convert=\(convertActive))")
    }

    private func makePanel() -> NSPanel {
        let split = clopActive && convertActive
        let size = NSSize(width: split ? 320 : 200, height: 118)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let kinds: [SuiteDropTargetKind] = split ? [.clop, .convert] : (clopActive ? [.clop] : [.convert])
        let halfWidth = size.width / CGFloat(kinds.count)
        for (index, kind) in kinds.enumerated() {
            let frame = NSRect(x: CGFloat(index) * halfWidth, y: 0, width: halfWidth, height: size.height)
            let target = SuiteDropTargetView(frame: frame, kind: kind)
            target.autoresizingMask = [.width, .height]
            target.onDrop = { [weak self] urls, kind in
                self?.hide()
                switch kind {
                case .clop: self?.onClopDrop?(urls)
                case .convert: self?.onConvertDrop?(urls)
                }
            }
            container.addSubview(target)
        }
        panel.contentView = container
        return panel
    }
}

private enum SuiteDropTargetKind {
    case clop, convert

    var symbol: String {
        switch self {
        case .clop: return "rectangle.compress.vertical"
        case .convert: return "arrow.triangle.2.circlepath"
        }
    }

    var title: String {
        switch self {
        case .clop: return "Optimize"
        case .convert: return "Convert"
        }
    }

    var caption: String {
        switch self {
        case .clop: return "Keeps format"
        case .convert: return "Uses your configured formats"
        }
    }

    func accepts(_ url: URL) -> Bool {
        switch self {
        case .clop: return ClopOptimizer.mediaType(forFileExtension: url.pathExtension) != nil
        case .convert: return ConvertPlan.mediaKind(forFileExtension: url.pathExtension) != nil
        }
    }
}

// The drag destination for one half (or the whole panel, single-target case).
// Visuals live in a hosted SwiftUI view; drags resolve to this container
// because only it registers for the file type.
private final class SuiteDropTargetView: NSView {
    var onDrop: (([URL], SuiteDropTargetKind) -> Void)?
    private let model: SuiteDropZoneVisualModel
    private let kind: SuiteDropTargetKind

    init(frame frameRect: NSRect, kind: SuiteDropTargetKind) {
        self.kind = kind
        self.model = SuiteDropZoneVisualModel(kind: kind)
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        let hosting = NSHostingView(rootView: SuiteDropZoneVisual(model: model))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unused: the drop zone is built in code")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = !supportedURLs(from: sender).isEmpty
        model.targeted = accepts
        return accepts ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        model.targeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        model.targeted = false
        let urls = supportedURLs(from: sender)
        guard !urls.isEmpty else { return false }
        Log.info("dropzone: \(urls.count) file(s) dropped on \(kind) half")
        onDrop?(urls, kind)
        return true
    }

    private func supportedURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { kind.accepts($0) }
    }
}

private final class SuiteDropZoneVisualModel: ObservableObject {
    @Published var targeted = false
    let kind: SuiteDropTargetKind

    init(kind: SuiteDropTargetKind) {
        self.kind = kind
    }
}

private struct SuiteDropZoneVisual: View {
    @ObservedObject var model: SuiteDropZoneVisualModel

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: model.kind.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(model.targeted ? Color.dsAccent : Color.dsMuted)
            Text(model.kind.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
            Text(model.kind.caption)
                .font(.system(size: 10))
                .foregroundStyle(Color.dsFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.dsInk1.opacity(0.97)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    model.targeted ? Color.dsAccent : Color.dsLine,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .padding(6)
        .animation(DS.animBase, value: model.targeted)
    }
}
