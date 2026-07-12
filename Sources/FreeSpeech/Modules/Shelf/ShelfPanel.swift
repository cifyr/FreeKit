import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FreeSpeechCore

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

    private var panel: NSPanel?
    private(set) var isVisible = false

    private static let panelSize = NSSize(width: 270, height: 280)

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
        panel.orderFrontRegardless()
        isVisible = true
        Log.info("shelf: panel shown (\(store.items.count) item(s))")
        onVisibilityChange?()
    }

    func close() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        isVisible = false
        if !keepItemsOnClose { store.clear() }
        Log.info("shelf: panel closed")
        onVisibilityChange?()
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
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)
        let root = ShelfPanelView(store: store, onClose: { [weak self] in self?.close() })
        panel.contentView = NSHostingView(rootView: root)
        return panel
    }
}

private struct ShelfPanelView: View {
    @ObservedObject var store: ShelfStore
    var onClose: () -> Void
    @State private var targeted = false

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
                CloseButton(action: onClose)
            }
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
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.items) { item in
                            ShelfRow(item: item) { store.remove(item) }
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
        .animation(.easeOut(duration: 0.12), value: targeted)
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
                .buttonStyle(.plain)
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
        // Standard file-URL drag: the destination sees the same URL a Finder
        // drag would deliver, so drops into folders, Slack, or mail all work.
        .onDrag { NSItemProvider(object: item.url as NSURL) }
    }
}
