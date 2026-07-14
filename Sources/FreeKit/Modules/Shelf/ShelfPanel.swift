import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FreeKitCore

// The shelf holds references, never copies: parking a file moves nothing on
// disk, and dragging a row out hands the same URL to the destination.
struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }

    var sizeLabel: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        return bytes.map { StatsFormatting.bytes(Double($0)) } ?? ""
    }
}

final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []

    func add(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL })
        let fresh = urls.filter {
            FileManager.default.fileExists(atPath: $0.path)
                && !existing.contains($0.standardizedFileURL)
        }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh.map { ShelfItem(url: $0) })
        Log.info("shelf: parked \(fresh.count) file(s), \(items.count) total")
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        guard !items.isEmpty else { return }
        Log.info("shelf: cleared \(items.count) item(s)")
        items.removeAll()
    }
}

final class ShelfPanelController {
    let store = ShelfStore()
    // Runtime preference, pushed in from module settings on every show.
    var keepItemsOnClose = false
    var onVisibilityChange: (() -> Void)?

    private let settings: Settings
    private let moduleID: String
    private var panel: NSPanel?
    private(set) var isVisible = false
    // Local catches clicks in our own app's windows, global catches everywhere
    // else; a borderless .nonactivatingPanel never becomes key, so there's no
    // resignKey notification to hook a dismiss-on-outside-click off of.
    private var outsideClickMonitors: [Any] = []

    private static let panelSize = NSSize(width: 270, height: 280)

    init(settings: Settings, moduleID: String) {
        self.settings = settings
        self.moduleID = moduleID
    }

    func show(near point: NSPoint) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if !isVisible {
            // Above-right of the cursor so it never sits under the item being
            // dragged, clamped so the whole panel stays on screen.
            let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
                ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            var origin = NSPoint(x: point.x + 24, y: point.y + 24)
            origin.x = min(max(visible.minX + 8, origin.x),
                           visible.maxX - Self.panelSize.width - 8)
            origin.y = min(max(visible.minY + 8, origin.y),
                           visible.maxY - Self.panelSize.height - 8)
            panel.setFrameOrigin(origin)
        }
        if isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.dsFadeIn()
        }
        isVisible = true
        installOutsideClickMonitors()
        Log.info("shelf: panel shown (\(store.items.count) item(s))")
        onVisibilityChange?()
    }

    func close() {
        guard isVisible else { return }
        panel?.dsFadeOut()
        isVisible = false
        removeOutsideClickMonitors()
        if !keepItemsOnClose { store.clear() }
        Log.info("shelf: panel closed")
        onVisibilityChange?()
    }

    // An empty shelf is just a target waiting to be dismissed: any click
    // elsewhere closes it. Once something's parked, an accidental click
    // shouldn't drop it, so only the X closes it from there on.
    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.dismissIfEmptyClickOutside() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            outsideClickMonitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            handler(event)
            return event
        }
        if let local { outsideClickMonitors.append(local) }
    }

    private func removeOutsideClickMonitors() {
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors.removeAll()
    }

    private func dismissIfEmptyClickOutside() {
        guard isVisible, store.items.isEmpty, let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        close()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Background dragging would consume the mouse drag AppKit needs to hand
        // to a row's .onDrag, so pulling a file off the shelf would just slide
        // the whole panel. The header strip is the drag handle instead.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)
        let settings = self.settings
        let moduleID = self.moduleID
        let root = ShelfPanelView(
            store: store,
            initialIconView: settings.moduleBool(id: moduleID, key: ShelfModule.Key.iconView) ?? false,
            onClose: { [weak self] in self?.close() },
            onViewModeChange: { iconView in
                settings.setModuleBool(iconView, id: moduleID, key: ShelfModule.Key.iconView)
            })
        panel.contentView = NSHostingView(rootView: root)
        return panel
    }
}

private struct ShelfPanelView: View {
    @ObservedObject var store: ShelfStore
    var onClose: () -> Void
    var onViewModeChange: (Bool) -> Void
    @State private var targeted = false
    // Set at construction, not via .onAppear: this panel's content view is
    // built once and reused across every show(), and .onAppear is not
    // reliably called again on a hidden-then-reshown NSHostingView.
    @State private var iconView: Bool

    init(store: ShelfStore, initialIconView: Bool, onClose: @escaping () -> Void,
         onViewModeChange: @escaping (Bool) -> Void) {
        self.store = store
        self.onClose = onClose
        self.onViewModeChange = onViewModeChange
        _iconView = State(initialValue: initialIconView)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("SHELF")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(Color.dsAccent)
                if !store.items.isEmpty {
                    Text("\(store.items.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dsFaint)
                }
                Spacer()
                ViewModeToggle(iconView: Binding(
                    get: { iconView },
                    set: { iconView = $0; onViewModeChange($0) }))
                CloseButton(action: onClose)
            }
            // Only the header moves the panel; everywhere else the mouse drag
            // has to stay available for dragging files out.
            .background(WindowDragHandle())
            if store.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(targeted ? Color.dsAccent : Color.dsMuted)
                    Text("Drop files here")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dsPaper)
                    Text("They stay parked until you drag them out.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dsFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if iconView {
                ScrollView {
                    ShelfIconGrid(items: store.items) { store.remove($0) }
                        .padding(.top, 2)
                }
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                            ShelfRow(item: item) { store.remove(item) }
                                .transition(.dsAppear)
                                .animation(DS.animAppear(index: index), value: store.items.count)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 270, height: 280)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.dsInk1.opacity(0.97)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Color.dsAccent : Color.dsLine, lineWidth: 1.5))
        .animation(DS.animInstant, value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadURLs(from: providers) { urls in store.add(urls) }
            return !providers.isEmpty
        }
    }

    private func loadURLs(from providers: [NSItemProvider],
                          completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url, url.isFileURL {
                    DispatchQueue.main.async { urls.append(url) }
                } else if let error {
                    Log.error("shelf: could not read dropped item: \(error.localizedDescription)")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

// Borderless panels have no title bar to grab. This hands mouseDown straight to
// the window so the header behaves like one, leaving the rest of the panel's
// mouse drags free for file drags. Shared with ModuleSettingsWindow, whose
// hidden-titlebar windows have the same problem.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragHandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// A big, unmissable close target: 26pt symbol in a 30pt hit area.
private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(hovering ? Color.dsPaper : Color.dsMuted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// Finder-style list/icons switch, tucked in the header next to the count.
private struct ViewModeToggle: View {
    @Binding var iconView: Bool

    var body: some View {
        HStack(spacing: 2) {
            modeButton("list.bullet", selected: !iconView) { iconView = false }
            modeButton("square.grid.2x2", selected: iconView) { iconView = true }
        }
    }

    private func modeButton(_ systemName: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.dsAccent : Color.dsMuted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ShelfRow: View {
    let item: ShelfItem
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dsPaper)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.sizeLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.dsFaint)
            }
            Spacer(minLength: 0)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.dsMuted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dsPress)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            hovering ? Color.dsInk3 : Color.dsInk2,
            in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous)
                .strokeBorder(Color.dsLine, lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(DS.animInstant, value: hovering)
        // Standard file-URL drag: the destination sees the same URL a Finder
        // drag would deliver, so drops into folders, Slack, or mail all work.
        .onDrag { NSItemProvider(object: item.url as NSURL) }
    }
}

private struct ShelfIconGrid: View {
    let items: [ShelfItem]
    let onRemove: (ShelfItem) -> Void
    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 64), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ShelfIconCell(item: item) { onRemove(item) }
                    .transition(.dsAppear)
                    .animation(DS.animAppear(index: index), value: items.count)
            }
        }
    }
}

private struct ShelfIconCell: View {
    let item: ShelfItem
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.dsPaper, Color.dsInk1)
                    }
                    .buttonStyle(.dsPress)
                    .offset(x: 6, y: -6)
                    .transition(.opacity)
                }
            }
            Text(item.name)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.dsPaper)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .frame(width: 64)
        .padding(6)
        .background(
            hovering ? Color.dsInk3 : Color.clear,
            in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
        .onHover { hovering = $0 }
        .animation(DS.animInstant, value: hovering)
        // Standard file-URL drag: the destination sees the same URL a Finder
        // drag would deliver, so drops into folders, Slack, or mail all work.
        .onDrag { NSItemProvider(object: item.url as NSURL) }
    }
}
