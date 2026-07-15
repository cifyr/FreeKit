import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import FreeKitCore

// The note panel is the suite's one light surface: a clean near-white sheet with
// ink text and crimson accents, deliberately apart from the dark control center
// that configures it. Scoped here so the rest of the suite's dark DS is untouched.
private enum NB {
    // Warm off-white house palette; the sheet itself is translucent (see
    // NotebookBackground) so these read as tints over a frosted wash, not solids.
    static let surface = NSColor(srgbRed: 0.961, green: 0.961, blue: 0.941, alpha: 1)   // F5F5F0
    static let bar = NSColor(srgbRed: 0.925, green: 0.925, blue: 0.902, alpha: 1)        // ECECE6
    static let ink = NSColor(srgbRed: 0.090, green: 0.090, blue: 0.090, alpha: 1)        // 171717
    static let muted = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.42, alpha: 1)         // 6B6B6B
    static let faint = NSColor(srgbRed: 0.58, green: 0.57, blue: 0.55, alpha: 1)         // 949188
    static let hairline = NSColor(srgbRed: 0.902, green: 0.890, blue: 0.882, alpha: 1)   // E6E3E1
    static let field = NSColor(srgbRed: 0.929, green: 0.929, blue: 0.902, alpha: 1)      // EDEDE6
    static let divider = NSColor(srgbRed: 0.82, green: 0.81, blue: 0.79, alpha: 1)       // D1CFCA
    static let accent = DS.accent
    static let selection = DS.accent.withAlphaComponent(0.16)

    static let surfaceC = Color(nsColor: surface)
    static let barC = Color(nsColor: bar)
    static let inkC = Color(nsColor: ink)
    static let mutedC = Color(nsColor: muted)
    static let faintC = Color(nsColor: faint)
    static let hairlineC = Color(nsColor: hairline)
    static let fieldC = Color(nsColor: field)
    static let accentC = Color(nsColor: DS.accent)
    static let hoverC = Color.black.opacity(0.05)
    static let selectionC = Color(nsColor: DS.accent).opacity(0.12)
}

// The note sheet's translucent, frosted backdrop: a warm off-white tint over a
// behind-window blur, with our signature crimson/gray wash blobs and film grain
// dialed down for a light surface. Empty areas here are the window-drag handle.
private struct NotebookBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground)
            NB.surfaceC.opacity(0.64)
            EllipticalGradient(
                colors: [NB.accentC.opacity(0.11), .clear],
                center: .topLeading, startRadiusFraction: 0, endRadiusFraction: 0.95)
            EllipticalGradient(
                colors: [NB.mutedC.opacity(0.10), .clear],
                center: .bottomTrailing, startRadiusFraction: 0, endRadiusFraction: 0.95)
            DSGrainOverlay(opacity: 0.09)
        }
        .ignoresSafeArea()
        .gesture(WindowDragGesture())
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

// Notebook: a floating note panel toggled by a global hotkey. Notes persist as
// RTF (round-trips bold/color/headings/bullets and stays readable by other
// apps) with a plain-text shadow for search, one file per note via NotebookStore.
final class NotebookModule: NSObject, AppModule, NSMenuDelegate {
    let info = ModuleCatalog.notebook

    private let settings: Settings
    private let hub: EventTapHub
    private var store: NotebookStore?
    private var hotkeyToken: EventTapHub.HotkeyToken?
    private var statusItem: NSStatusItem?
    private var panel: NotebookPanelController?
    private var config: NotebookConfig?

    // Ctrl+Opt+N: mnemonic for "note", off the Cmd namespace apps use.
    private static let defaultHotkey = HotkeyPreset.custom(
        keyCode: 45, modifiers: [.control, .option])

    init(settings: Settings, hub: EventTapHub) {
        self.settings = settings
        self.hub = hub
        super.init()
    }

    private var hotkey: HotkeyPreset {
        settings.moduleHotkey(id: info.id, defaultPreset: Self.defaultHotkey)
    }

    func activate() {
        if store == nil {
            store = NotebookStore(directory: AppPaths.notesDir)
        }
        guard let store else { return }
        if config == nil {
            config = NotebookConfig(settings: settings)
        }
        if panel == nil, let config {
            panel = NotebookPanelController(store: store, config: config) { [weak self] in
                self?.openSettings()
            }
        }
        if hotkeyToken == nil {
            hotkeyToken = hub.register(preset: hotkey, label: "notebook.toggle") { [weak self] direction in
                guard direction == .down else { return }
                self?.panel?.toggle()
            }
        }
    }

    func deactivate() {
        if let hotkeyToken { hub.unregister(hotkeyToken) }
        hotkeyToken = nil
        panel?.hide()
    }

    func setMenuBarItemVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(
                    systemSymbolName: info.symbolName, accessibilityDescription: "Notebook")
                item.button?.toolTip = "Notebook"
                let menu = NSMenu()
                menu.delegate = self
                item.menu = menu
                statusItem = item
            }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    // Settings stay an in-hub modal; the notes panel is Notebook's own window.
    var settingsPopupSize: NSSize { NSSize(width: 580, height: 660) }

    func makeSettingsPane() -> AnyView {
        // Settings can open while the module is off; the config is cheap and
        // settings-backed, so build it on demand.
        let config = self.config ?? NotebookConfig(settings: settings)
        self.config = config
        return AnyView(NotebookSettingsPane(
            config: config,
            hotkey: hotkey,
            onHotkeyChange: { [weak self] preset in
                guard let self else { return }
                self.settings.setModuleHotkey(preset, id: self.info.id)
                if let token = self.hotkeyToken {
                    self.hub.update(token, preset: preset)
                }
            }))
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let newNote = NSMenuItem(
            title: "New Note", action: #selector(newNote), keyEquivalent: "")
        newNote.target = self
        menu.addItem(newNote)
        let open = NSMenuItem(
            title: "Open Notebook (\(hotkey.displayName))", action: #selector(openNotebook),
            keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let recent = store?.notes().prefix(5) ?? []
        if !recent.isEmpty {
            menu.addItem(.separator())
            for note in recent {
                let title = note.title.isEmpty ? "Untitled" : note.title
                let item = NSMenuItem(
                    title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = note.id.uuidString
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Notebook Settings\u{2026}", action: #selector(openSettingsFromMenu),
            keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    @objc private func newNote() {
        panel?.showNewNote()
    }

    @objc private func openNotebook() {
        panel?.show()
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        panel?.show(selecting: id)
    }
}

// MARK: - Config

enum NotebookFont: String, CaseIterable, Equatable {
    case system, serif, mono

    var displayName: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }
}

enum NotebookListDensity: String, CaseIterable {
    case compact, comfortable

    var displayName: String { rawValue.capitalized }
}

// Settings-backed knobs the panel reacts to live.
final class NotebookConfig: ObservableObject {
    private let settings: Settings
    private let id = ModuleCatalog.notebook.id

    @Published var fontSize: Double {
        didSet { settings.setModuleDouble(fontSize, id: id, key: "fontSize") }
    }
    @Published var fontFamily: NotebookFont {
        didSet { settings.setModuleString(fontFamily.rawValue, id: id, key: "fontFamily") }
    }
    @Published var sidebarVisible: Bool {
        didSet { settings.setModuleBool(sidebarVisible, id: id, key: "sidebarVisible") }
    }
    @Published var floatOnTop: Bool {
        didSet { settings.setModuleBool(floatOnTop, id: id, key: "floatOnTop") }
    }
    @Published var sidebarWidth: Double {
        didSet { settings.setModuleDouble(sidebarWidth, id: id, key: "sidebarWidth") }
    }
    @Published var listDensity: NotebookListDensity {
        didSet { settings.setModuleString(listDensity.rawValue, id: id, key: "listDensity") }
    }
    @Published var sortOrder: NotebookSortOrder {
        didSet { settings.setModuleString(sortOrder.rawValue, id: id, key: "sortOrder") }
    }
    @Published var showTimestamps: Bool {
        didSet { settings.setModuleBool(showTimestamps, id: id, key: "showTimestamps") }
    }
    @Published var showPreviews: Bool {
        didSet { settings.setModuleBool(showPreviews, id: id, key: "showPreviews") }
    }
    @Published var spellCheck: Bool {
        didSet { settings.setModuleBool(spellCheck, id: id, key: "spellCheck") }
    }
    @Published var smartQuotes: Bool {
        didSet { settings.setModuleBool(smartQuotes, id: id, key: "smartQuotes") }
    }

    init(settings: Settings) {
        self.settings = settings
        fontSize = settings.moduleDouble(id: id, key: "fontSize") ?? 13
        fontFamily = settings.moduleString(id: id, key: "fontFamily")
            .flatMap(NotebookFont.init) ?? .system
        // Sidebar starts hidden; it's summoned from the in-app toolbar.
        sidebarVisible = settings.moduleBool(id: id, key: "sidebarVisible") ?? false
        floatOnTop = settings.moduleBool(id: id, key: "floatOnTop") ?? true
        sidebarWidth = min(max(settings.moduleDouble(id: id, key: "sidebarWidth") ?? 210, 180), 300)
        sortOrder = settings.moduleString(id: id, key: "sortOrder")
            .flatMap(NotebookSortOrder.init) ?? .modified
        // Previews, timestamps, and comfortable density are always on now — no
        // longer exposed as settings — so they're fixed rather than read back.
        listDensity = .comfortable
        showTimestamps = true
        showPreviews = true
        spellCheck = settings.moduleBool(id: id, key: "spellCheck") ?? true
        smartQuotes = settings.moduleBool(id: id, key: "smartQuotes") ?? true
    }

    func font(size: Double, weight: NSFont.Weight = .regular) -> NSFont {
        switch fontFamily {
        case .system:
            return .systemFont(ofSize: size, weight: weight)
        case .serif:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = base.fontDescriptor.withDesign(.serif),
               let serif = NSFont(descriptor: descriptor, size: size) {
                return serif
            }
            return base
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    func font(for level: RichTextEditorProxy.HeadingLevel) -> NSFont {
        switch level {
        case .title: return font(size: fontSize + 8, weight: .bold)
        case .heading: return font(size: fontSize + 3, weight: .semibold)
        case .body: return font(size: fontSize)
        }
    }

    // No extra line/paragraph spacing. On macOS 26 the caret is the system text
    // insertion indicator, drawn at the line-fragment height and not resizable
    // independently, so ANY lineSpacing or paragraphSpacing stretches it taller
    // than the text. Default line height keeps the caret at text height.
    static func bodyParagraphStyle(fontSize: CGFloat) -> NSMutableParagraphStyle {
        NSMutableParagraphStyle()
    }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font(size: fontSize),
            .foregroundColor: NB.ink,
            .paragraphStyle: Self.bodyParagraphStyle(fontSize: fontSize),
        ]
    }
}

// MARK: - Panel

final class NotebookPanelController {
    private var panel: NSPanel?
    private let model: NotebookViewModel
    private let config: NotebookConfig
    private var floatCancellable: AnyCancellable?

    init(store: NotebookStore, config: NotebookConfig, openSettings: @escaping () -> Void) {
        self.config = config
        model = NotebookViewModel(store: store, config: config, openSettings: openSettings)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // Hidden -> show and focus. Visible but in the background -> bring to the
    // front and focus (hiding here is what made the hotkey feel broken: from
    // another app the "toggle" would vanish a panel you could barely see).
    // Visible and focused -> hide.
    func toggle() {
        guard let panel, panel.isVisible else {
            show()
            return
        }
        if panel.isKeyWindow {
            hide()
        } else {
            focus()
        }
    }

    func show(selecting id: UUID? = nil) {
        buildIfNeeded()
        model.refresh()
        if let id, id != model.selectedID {
            model.select(id)
        } else if model.selectedID != nil {
            // Re-opening the panel on the same note is an "open": pull its
            // Apple Notes copy so edits made in Notes.app show up.
            model.reopenSelectedForSync()
        }
        if model.selectedID == nil { model.selectFirstOrCreate() }
        focus()
    }

    func showNewNote() {
        buildIfNeeded()
        model.refresh()
        model.newNote()
        focus()
    }

    func hide() {
        model.flushPendingSave()
        // Hiding the panel "closes" the open note: push it to Apple Notes.
        model.autoSyncCloseSelected()
        if let panel { DSMotionAppKit.dismissWindow(panel, close: false) }
    }

    private func focus() {
        if let panel {
            // Re-assert the float level and force it frontmost. No NSApp.activate:
            // as a .nonactivatingPanel it takes key for typing without activating
            // the app, which would otherwise yank a full-screen Space back to our
            // desktop instead of overlaying the note on top of it.
            panel.level = config.floatOnTop ? .floating : .normal
            DSMotionAppKit.presentWindow(panel)
            panel.orderFrontRegardless()
            panel.makeKey()
        }
        model.focusEditor()
    }

    private func buildIfNeeded() {
        guard panel == nil else { return }
        let hosting = NSHostingController(
            rootView: NotebookView(model: model, config: config, onClose: { [weak self] in self?.hide() }))
        // A titled, floating panel: stays over normal windows for quick capture.
        // fullScreenAuxiliary lets it also surface over another app's full-screen
        // Space (e.g. jotting a note while a video plays full-screen) without the
        // panel taking over or stealing that Space's full-screen focus itself.
        let p = NSPanel(contentViewController: hosting)
        // .nonactivatingPanel: becomes key for text entry without activating the
        // app, so summoning it over another app's full-screen Space overlays in
        // place instead of pulling the Space back to our regular desktop.
        p.styleMask = [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView]
        p.title = "Notebook"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.appearance = NSAppearance(named: .aqua)
        // Translucent: the SwiftUI root paints the frosted warm wash; the window
        // stays clear so it reads through to whatever is behind it.
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = config.floatOnTop ? .floating : .normal
        // canJoinAllSpaces + fullScreenAuxiliary regardless of the float toggle,
        // so it can surface onto an active full-screen Space.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        // Explicit drag surfaces only (the background wash), never controls;
        // see NotebookBackground's WindowDragGesture.
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 480, height: 340)
        p.setContentSize(NSSize(width: 680, height: 440))
        if !p.setFrameUsingName("FreeKit.NotebookPanel") { p.center() }
        p.setFrameAutosaveName("FreeKit.NotebookPanel")
        // Traffic lights only while focused: hidden as the panel floats over
        // another app, shown once it's clicked into (mirrors the ✕ in the bar).
        Self.setTrafficLights(p, hidden: true)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: p, queue: .main
        ) { [weak p] _ in if let p { Self.setTrafficLights(p, hidden: false) } }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak p] _ in if let p { Self.setTrafficLights(p, hidden: true) } }
        // The close button bypasses hide(): still a "close" for sync purposes.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: p, queue: .main
        ) { [weak self] _ in
            self?.model.flushPendingSave()
            self?.model.autoSyncCloseSelected()
        }
        panel = p
        floatCancellable = config.$floatOnTop.sink { [weak p] onTop in
            p?.level = onTop ? .floating : .normal
        }
    }

    private static func setTrafficLights(_ window: NSWindow, hidden: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = hidden
        }
    }
}

// MARK: - View model

final class NotebookViewModel: ObservableObject {
    @Published var query: String = "" { didSet { refresh() } }
    @Published private(set) var notes: [Note] = []
    @Published var selectedID: UUID?
    // The dedicated header field; empty falls back to the first content line.
    @Published var editedTitle: String = "" {
        didSet { if editedTitle != oldValue { titleChanged() } }
    }
    // Bumped when the editor must reload its content (selection change).
    @Published private(set) var loadGeneration = 0
    private(set) var loadedText = NSAttributedString()
    weak var editorTextView: NSTextView?

    private let store: NotebookStore
    let config: NotebookConfig
    let openSettings: () -> Void
    private var saveTimer: Timer?
    private var pendingSave: (id: UUID, text: NSAttributedString)?
    private var titleDirty = false
    private var suppressTitleCallback = false

    init(store: NotebookStore, config: NotebookConfig, openSettings: @escaping () -> Void) {
        self.store = store
        self.config = config
        self.openSettings = openSettings
        refresh()
    }

    func refresh() {
        notes = store.search(query, sortedBy: config.sortOrder)
    }

    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let tv = self?.editorTextView else { return }
            tv.window?.makeFirstResponder(tv)
        }
    }

    func select(_ id: UUID) {
        flushPendingSave()
        // Leaving one note and opening another is the sync boundary: push the
        // outgoing copy, pull the incoming one, both silently.
        if let previous = selectedID, previous != id { autoSyncClose(previous) }
        if selectedID != id { autoSyncOpen(id) }
        guard store.note(id: id) != nil else { return }
        selectedID = id
        reloadSelected()
        armPeriodicSync(for: id)
    }

    // Re-sync the already-selected note when the panel is summoned again.
    func reopenSelectedForSync() {
        guard let id = selectedID else { return }
        flushPendingSave()
        autoSyncOpen(id)
        reloadSelected()
        armPeriodicSync(for: id)
    }

    private func reloadSelected() {
        guard let id = selectedID, let note = store.note(id: id) else { return }
        suppressTitleCallback = true
        editedTitle = note.title
        suppressTitleCallback = false
        loadedText = attributedText(from: note)
        loadGeneration += 1
    }

    func selectFirstOrCreate() {
        if let first = notes.first {
            select(first.id)
        } else {
            newNote()
        }
    }

    func newNote() {
        flushPendingSave()
        let note = Note()
        store.upsert(note)
        query = ""
        refresh()
        select(note.id)
    }

    func delete(_ id: UUID) {
        flushPendingSave()
        store.delete(id: id)
        if selectedID == id {
            selectedID = nil
            disarmPeriodicSync()
            suppressTitleCallback = true
            editedTitle = ""
            suppressTitleCallback = false
            loadedText = NSAttributedString()
            loadGeneration += 1
        }
        refresh()
    }

    private func titleChanged() {
        guard !suppressTitleCallback, selectedID != nil else { return }
        titleDirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.flushPendingSave()
            self?.refresh()
        }
    }

    // Debounced: every keystroke schedules, disk sees at most ~2 writes/second.
    func textDidChange(_ text: NSAttributedString) {
        guard let id = selectedID else { return }
        pendingSave = (id, text.copy() as! NSAttributedString)
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.flushPendingSave()
            self?.refresh()
        }
    }

    func flushPendingSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        let saved = pendingSave
        pendingSave = nil
        let wasTitleDirty = titleDirty
        titleDirty = false
        guard saved != nil || wasTitleDirty else { return }
        guard let id = saved?.id ?? selectedID, var note = store.note(id: id) else { return }
        if let (_, text) = saved {
            note.plainText = text.string
            note.rich = NotebookRichText.data(from: text)
        }
        // Explicit header wins; an empty header falls back to the first line.
        let typed = editedTitle.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            let firstLine = note.plainText.split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            note.title = String(firstLine.prefix(60))
        } else {
            note.title = String(typed.prefix(60))
        }
        note.modified = Date()
        store.upsert(note)
    }

    private func attributedText(from note: Note) -> NSAttributedString {
        if let rich = note.rich,
           let text = NotebookRichText.attributedString(from: rich) {
            return text
        }
        return NSAttributedString(string: note.plainText, attributes: config.bodyAttributes)
    }

    // MARK: - Apple Notes sync

    // FreeKit notes mirror into Apple Notes invisibly, with no button or
    // status text anywhere in the UI: opening a linked note merges against its
    // Notes copy, leaving one (switching notes, hiding the panel, closing the
    // window) merges again, and a repeating timer merges the open note every
    // periodicSyncInterval while it's being edited, so a save doesn't wait for
    // a close to reach Apple Notes. "Merge" keeps whichever side was edited most
    // recently rather than blindly overwriting — so an edit in Notes.app carries
    // over, but a deletion made in FreeKit isn't undone by the (longer) stale
    // Notes copy the way an earlier "more content wins" rule did.
    // A note earns its Apple Notes counterpart in the FreeKit folder on first
    // close; notes made outside FreeKit are never imported.
    private static let periodicSyncInterval: TimeInterval = 45
    private var periodicSyncTimer: Timer?
    // After an Automation denial the sync path stays quiet instead of
    // re-failing on every timer tick and open/close.
    private var autoSyncSuspended = false

    func autoSyncCloseSelected() {
        disarmPeriodicSync()
        guard let id = selectedID else { return }
        autoSyncClose(id)
    }

    fileprivate func autoSyncClose(_ id: UUID) {
        guard !autoSyncSuspended, let note = store.note(id: id) else { return }
        // Empty scratch notes don't earn an Apple Notes counterpart.
        let hasContent = !note.title.isEmpty
            || !note.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard note.appleNoteID != nil || hasContent else { return }
        syncMerge(id: id)
    }

    fileprivate func autoSyncOpen(_ id: UUID) {
        guard !autoSyncSuspended, let note = store.note(id: id),
              note.appleNoteID != nil else { return }
        syncMerge(id: id)
    }

    private func armPeriodicSync(for id: UUID) {
        periodicSyncTimer?.invalidate()
        guard !autoSyncSuspended else { periodicSyncTimer = nil; return }
        periodicSyncTimer = Timer.scheduledTimer(
            withTimeInterval: Self.periodicSyncInterval, repeats: true
        ) { [weak self] _ in
            self?.periodicSync(id)
        }
    }

    private func disarmPeriodicSync() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
    }

    private func periodicSync(_ id: UUID) {
        guard selectedID == id else { disarmPeriodicSync(); return }
        flushPendingSave()
        autoSyncClose(id)
    }

    // Reconciles the local note against its Apple Notes copy, keeping
    // whichever side has more (trimmed) text and pushing that version to the
    // other side so both converge instead of one clobbering the other.
    private func syncMerge(id: UUID) {
        guard let note = store.note(id: id) else { return }
        guard let appleID = note.appleNoteID else {
            syncPush(note: note)
            return
        }
        switch Self.runAppleScript(AppleNotesScript.pullWithModified(id: appleID)) {
        case .success(let descriptor):
            // The script returns {body, modification date}; a list descriptor is
            // 1-indexed. Fall back to a plain push if it isn't shaped as expected.
            guard descriptor.numberOfItems >= 2,
                  let html = descriptor.atIndex(1)?.stringValue,
                  let remoteModified = descriptor.atIndex(2)?.dateValue,
                  let (title, content) = Self.parsePulledHTML(html, config: config) else {
                syncPush(note: note)
                return
            }
            // Most-recently-edited side wins. The epsilon absorbs the second or
            // two between our own push and Notes stamping it, so a note we just
            // pushed doesn't read as "remote is newer" and get adopted back.
            if remoteModified > note.modified.addingTimeInterval(2) {
                var updated = note
                if !title.isEmpty { updated.title = String(title.prefix(60)) }
                updated.plainText = content.string
                updated.rich = NotebookRichText.data(from: content)
                updated.modified = remoteModified
                store.upsert(updated)
                Log.info("notebook: adopted Apple Notes copy for \(note.id) (remote modified \(remoteModified) > local \(note.modified))")
                if selectedID == id {
                    refresh()
                    reloadSelected()
                }
            } else {
                syncPush(note: note)
            }
        case .failure(let failure):
            handleSyncFailure(failure, note: note, operation: "sync")
        }
    }

    @discardableResult
    private func syncPush(note: Note) -> Bool {
        let html = Self.htmlForPush(note: note)
        let script = AppleNotesScript.push(htmlBody: html, existingID: note.appleNoteID)
        Log.info("notebook: pushing note \(note.id) to Apple Notes (linked=\(note.appleNoteID != nil), htmlBytes=\(html.utf8.count))")
        switch Self.runAppleScript(script) {
        case .success(let descriptor):
            var updated = store.note(id: note.id) ?? note
            if let newID = descriptor.stringValue, !newID.isEmpty {
                updated.appleNoteID = newID
            }
            // Notes stamps its own modification date to now on this write; match
            // it locally so the next merge sees the two copies as even (recency
            // tie) and pushes/does nothing rather than adopting the round-tripped
            // remote back over the local original.
            updated.modified = Date()
            store.upsert(updated)
            Log.info("notebook: pushed note \(note.id) -> Apple Notes id \(updated.appleNoteID ?? "?")")
            return true
        case .failure(let failure):
            handleSyncFailure(failure, note: note, operation: "push")
            return false
        }
    }

    private func handleSyncFailure(_ failure: AppleScriptFailure, note: Note, operation: String) {
        Log.error("notebook: Apple Notes \(operation) failed for \(note.id) (\(failure.code.map(String.init) ?? "?")): \(failure.message)")
        if failure.isMissingNote {
            // Deleted in Notes.app: unlink so the next close re-creates it
            // instead of failing forever.
            var updated = store.note(id: note.id) ?? note
            updated.appleNoteID = nil
            store.upsert(updated)
            return
        }
        if failure.isAutomationDenied {
            autoSyncSuspended = true
            disarmPeriodicSync()
            Log.error("notebook: Apple Notes automation not permitted; pausing sync until FreeKit is relaunched or Automation access is granted in Privacy & Security")
        }
    }

    struct AppleScriptFailure: Error {
        let code: Int?
        let message: String
        // -1743 is errAEEventNotPermitted: the user declined (or has not yet
        // been asked for) Automation consent for Notes.
        var isAutomationDenied: Bool { code == -1743 }
        // -1728: "can't get note id ..." — the linked note is gone.
        var isMissingNote: Bool { code == -1728 }
    }

    // Runs on the main thread: NSAppleScript is not thread-safe, and both
    // existing Finder automations in the suite run it the same way.
    private static func runAppleScript(_ source: String)
        -> Result<NSAppleEventDescriptor, AppleScriptFailure> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(AppleScriptFailure(code: nil, message: "script construction failed"))
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return .failure(AppleScriptFailure(
                code: errorInfo[NSAppleScript.errorNumber] as? Int,
                message: (errorInfo[NSAppleScript.errorMessage] as? String) ?? "\(errorInfo)"))
        }
        return .success(result)
    }

    // Title becomes the body's first (heading) line — Notes derives the note
    // name from it — followed by the content, exported together as HTML.
    private static func htmlForPush(note: Note) -> String {
        let content = note.rich.flatMap { NotebookRichText.attributedString(from: $0) }
            ?? NSAttributedString(string: note.plainText)
        let combined = NSMutableAttributedString()
        let title = note.title.isEmpty ? "Untitled" : note.title
        combined.append(NSAttributedString(
            string: title + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold)]))
        combined.append(normalizedForExport(content))
        let range = NSRange(location: 0, length: combined.length)
        guard let data = try? combined.data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]),
            let html = String(data: data, encoding: .utf8) else {
            // Plain-text fallback keeps push working even if HTML export fails.
            return "<div><b>\(title)</b></div><div>" + note.plainText + "</div>"
        }
        return html
    }

    // First line comes back as the title; the rest is the content, recolored
    // for the dark editor. Best-effort fidelity: bold/italic/lists survive,
    // Notes-specific attachments do not.
    private static func parsePulledHTML(_ html: String, config: NotebookConfig)
        -> (title: String, content: NSAttributedString)? {
        guard let data = html.data(using: .utf8),
              let parsed = NSAttributedString(
                html: data,
                options: [.characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else { return nil }
        let text = parsed.string as NSString
        let firstBreak = text.range(of: "\n")
        let title: String
        let contentRange: NSRange
        if firstBreak.location != NSNotFound {
            title = text.substring(to: firstBreak.location)
                .trimmingCharacters(in: .whitespaces)
            let start = firstBreak.location + firstBreak.length
            contentRange = NSRange(location: start, length: parsed.length - start)
        } else {
            title = text.trimmingCharacters(in: .whitespaces)
            contentRange = NSRange(location: 0, length: 0)
        }
        let content = parsed.attributedSubstring(from: contentRange)
        return (title, normalizedForImport(content, config: config))
    }

    // Both Notes and this editor now render dark-on-light, so text mostly passes
    // through: on export, our near-ink body drops its explicit color so Notes
    // uses its own default black; on import, absent or near-white (invisible-on-
    // light) text is coerced to ink. Deliberate colors (reds, blues) pass through.
    private static func normalizedForExport(_ text: NSAttributedString) -> NSAttributedString {
        recolor(text) { color in
            brightness(of: color).map { $0 < 0.2 ? nil : color } ?? color
        }
    }

    private static func normalizedForImport(
        _ text: NSAttributedString, config: NotebookConfig
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
            let color = value as? NSColor
            let bright = color.flatMap(brightness(of:))
            if color == nil || (bright ?? 1) > 0.8 {
                result.addAttribute(.foregroundColor, value: NB.ink, range: sub)
            }
        }
        // Notes' typefaces never enter the notebook: everything lands in this
        // notebook's own face at body size, keeping only bold/italic.
        let manager = NSFontManager.shared
        result.enumerateAttribute(.font, in: range) { value, sub, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var font = config.font(size: config.fontSize)
            if traits.contains(.bold) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
            if traits.contains(.italic) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            result.addAttribute(.font, value: font, range: sub)
        }
        return result
    }

    // Transform returning nil removes the explicit color on that run.
    private static func recolor(
        _ text: NSAttributedString, _ transform: (NSColor) -> NSColor?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: result.length)
        ) { value, sub, _ in
            guard let color = value as? NSColor else { return }
            if let replacement = transform(color) {
                result.addAttribute(.foregroundColor, value: replacement, range: sub)
            } else {
                result.removeAttribute(.foregroundColor, range: sub)
            }
        }
        return result
    }

    private static func brightness(of color: NSColor) -> CGFloat? {
        color.usingColorSpace(.sRGB)?.brightnessComponent
    }
}

// MARK: - Views

struct NotebookView: View {
    @ObservedObject var model: NotebookViewModel
    @ObservedObject var config: NotebookConfig
    let onClose: () -> Void
    @Environment(\.controlActiveState) private var controlActiveState
    @ObservedObject private var appearance = AppearanceManager.shared
    @StateObject private var editor = RichTextEditorProxy()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    // Content colors are user data, not interface chrome, so the palette here
    // deliberately goes beyond the DS accent (Google-Docs-style choice).
    private static let textColors: [(NSColor, String)] = [
        (NB.ink, "Default"), (NB.muted, "Muted"), (.systemGray, "Gray"),
        (DS.accent, "Red"), (.systemOrange, "Orange"), (.systemYellow, "Yellow"),
        (.systemGreen, "Green"), (.systemMint, "Mint"), (.systemTeal, "Teal"),
        (.systemBlue, "Blue"), (.systemIndigo, "Indigo"), (.systemPurple, "Purple"),
        (.systemPink, "Pink"), (.systemBrown, "Brown"),
    ]

    private static let highlightColors: [(NSColor, String)] = [
        (NSColor.systemYellow.withAlphaComponent(0.35), "Yellow"),
        (NSColor.systemGreen.withAlphaComponent(0.35), "Green"),
        (NSColor.systemBlue.withAlphaComponent(0.35), "Blue"),
        (NSColor.systemPink.withAlphaComponent(0.35), "Pink"),
        (NSColor.systemPurple.withAlphaComponent(0.35), "Purple"),
        (DS.accent.withAlphaComponent(0.35), "Red"),
    ]

    private static let fontSizes: [Double] = [10, 12, 13, 14, 16, 18, 20, 24, 28]

    @State private var showTextColors = false
    @State private var showHighlights = false
    @State private var showSizes = false
    @State private var showOverflow = false

    var body: some View {
        ZStack {
            NotebookBackground()
            HStack(spacing: 0) {
                if config.sidebarVisible {
                    sidebar
                    Rectangle().fill(NB.hairlineC).frame(width: 1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    // Centered so it clears the (left-hung) traffic lights; doubles
                    // as the panel's title the way the reference app's header reads.
                    // No fill: empty title-row space falls through to the drag wash.
                    TextField("Untitled", text: $model.editedTitle)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NB.inkC)
                        .padding(.horizontal, 72)
                        .padding(.top, 5)
                        .padding(.bottom, 6)
                    RichTextEditor(model: model, proxy: editor)
                    Rectangle().fill(NB.hairlineC).frame(height: 1)
                    GeometryReader { geo in
                        bottomBar(width: geo.size.width)
                    }
                    .frame(height: 46)
                    .background(NB.barC.opacity(0.45).gesture(WindowDragGesture()))
                }
            }
        }
        .frame(minWidth: 480, minHeight: 340)
        .animation(DS.animBase, value: config.sidebarVisible)
        .onChange(of: config.sortOrder) { _, _ in model.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NB.faintC)
                TextField("Search notes", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(NB.inkC)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                NB.fieldC,
                in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                    .strokeBorder(NB.hairlineC, lineWidth: 1))

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.notes) { note in
                        NoteRow(
                            note: note,
                            selected: model.selectedID == note.id,
                            timeFormatter: Self.timeFormatter,
                            density: config.listDensity,
                            showTimestamp: config.showTimestamps,
                            showPreview: config.showPreviews,
                            onSelect: { model.select(note.id) },
                            onDelete: { model.delete(note.id) })
                            .transition(.dsAppear)
                            .animation(DS.animBase, value: model.notes.count)
                    }
                }
            }

            Button(action: { model.newNote() }) {
                Text("New Note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NB.accentC)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(NB.fieldC, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: config.sidebarWidth)
        .background(NB.surfaceC.opacity(0.4).gesture(WindowDragGesture()))
    }

    // MARK: Adaptive one-line toolbar

    // Display-ordered tool groups; lower keepPriority survives narrow widths
    // longer. Whatever does not fit moves into the trailing ellipsis panel.
    private enum ToolGroup: CaseIterable {
        case headings, styles, colorTools, lists, alignment

        var buttonCount: Int {
            switch self {
            case .headings: return 3
            case .styles: return 4
            case .colorTools: return 3
            case .lists: return 2
            case .alignment: return 3
            }
        }

        var keepPriority: Int {
            switch self {
            case .styles: return 0
            case .headings: return 1
            case .colorTools: return 2
            case .lists: return 3
            case .alignment: return 4
            }
        }

        // Button width 30 + 4 spacing, plus the leading divider.
        var width: CGFloat { CGFloat(buttonCount) * 34 + 13 }
    }

    private func visibleGroups(width: CGFloat) -> Set<ToolGroup> {
        // Fixed occupants: padding + sidebar, image, overflow, close, gear slots.
        var budget = width - 24 - 34 * 5
        var kept: Set<ToolGroup> = []
        for group in ToolGroup.allCases.sorted(by: { $0.keepPriority < $1.keepPriority }) {
            if budget >= group.width {
                kept.insert(group)
                budget -= group.width
            }
        }
        return kept
    }

    private func bottomBar(width: CGFloat) -> some View {
        let visible = visibleGroups(width: width)
        let hidden = ToolGroup.allCases.filter { !visible.contains($0) }
        return HStack(spacing: 4) {
            formatButton("sidebar.left", help: config.sidebarVisible ? "Hide sidebar" : "Show sidebar") {
                config.sidebarVisible.toggle()
            }
            formatButton("photo", help: "Insert image") { editor.insertImageFromPanel() }
            ForEach(ToolGroup.allCases.filter { visible.contains($0) }, id: \.self) { group in
                barDivider
                inlineGroup(group)
            }
            Spacer(minLength: 4)
            if !hidden.isEmpty {
                formatButton("ellipsis", help: "More tools") { showOverflow.toggle() }
                    .popover(isPresented: $showOverflow, arrowEdge: .top) {
                        overflowPanel(groups: hidden)
                    }
            }
            // Only offer close once the panel is focused; while it floats over
            // another app there's nothing to "close into", matching the reference.
            if controlActiveState != .inactive {
                barDivider
                formatButton("xmark", help: "Close notebook") { onClose() }
            }
            barDivider
            formatButton("gearshape", help: "Notebook settings") { model.openSettings() }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private var barDivider: some View {
        Rectangle().fill(NB.hairlineC).frame(width: 1, height: 18)
    }

    @ViewBuilder private func inlineGroup(_ group: ToolGroup) -> some View {
        switch group {
        case .headings:
            headingButtons
        case .styles:
            styleButtons
        case .colorTools:
            formatButton("paintbrush.pointed", help: "Text color") { showTextColors.toggle() }
                .popover(isPresented: $showTextColors, arrowEdge: .top) {
                    colorGrid(Self.textColors, clearTitle: nil) { color in
                        editor.applyColor(color ?? NB.ink)
                    }
                }
            formatButton("highlighter", help: "Highlight") { showHighlights.toggle() }
                .popover(isPresented: $showHighlights, arrowEdge: .top) {
                    colorGrid(Self.highlightColors, clearTitle: "None") { color in
                        editor.applyHighlight(color)
                    }
                }
            formatButton("textformat.size.smaller", help: "Text size") { showSizes.toggle() }
                .popover(isPresented: $showSizes, arrowEdge: .top) {
                    sizeList { showSizes = false }
                }
        case .lists:
            listButtons
        case .alignment:
            alignmentButtons
        }
    }

    // The overflow panel expands popover-style tools inline: nesting popovers
    // inside a popover is fragile on macOS.
    private func overflowPanel(groups: [ToolGroup]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups, id: \.self) { group in
                switch group {
                case .headings:
                    HStack(spacing: 6) { headingButtons }
                case .styles:
                    HStack(spacing: 6) { styleButtons }
                case .colorTools:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TEXT COLOR")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .kerning(1.0)
                            .foregroundStyle(NB.faintC)
                        swatchRow(Self.textColors) { editor.applyColor($0 ?? NB.ink) }
                        Text("HIGHLIGHT")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .kerning(1.0)
                            .foregroundStyle(NB.faintC)
                        HStack(spacing: 6) {
                            swatchRow(Self.highlightColors) { editor.applyHighlight($0) }
                            Button("None") { editor.applyHighlight(nil) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(NB.mutedC)
                        }
                        Text("SIZE")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .kerning(1.0)
                            .foregroundStyle(NB.faintC)
                        HStack(spacing: 4) {
                            ForEach(Self.fontSizes, id: \.self) { size in
                                Button("\(Int(size))") { editor.applyFontSize(size) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(NB.inkC)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(NB.fieldC, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                case .lists:
                    HStack(spacing: 6) { listButtons }
                case .alignment:
                    HStack(spacing: 6) { alignmentButtons }
                }
            }
        }
        .padding(12)
        .background(NB.barC)
    }

    @ViewBuilder private var headingButtons: some View {
        formatButton("textformat.size.larger", help: "Title") {
            editor.applyHeading(font: config.font(for: .title))
        }
        formatButton("textformat.size", help: "Heading") {
            editor.applyHeading(font: config.font(for: .heading))
        }
        formatButton("textformat", help: "Body text") {
            editor.applyHeading(font: config.font(for: .body))
        }
    }

    @ViewBuilder private var styleButtons: some View {
        formatButton("bold", help: "Bold") { editor.toggleBold() }
        formatButton("italic", help: "Italic") { editor.toggleItalic() }
        formatButton("underline", help: "Underline") { editor.toggleUnderline() }
        formatButton("strikethrough", help: "Strikethrough") { editor.toggleStrikethrough() }
    }

    @ViewBuilder private var listButtons: some View {
        formatButton("list.bullet", help: "Bullet list") { editor.toggleBullets() }
        formatButton("rectangle.split.1x2", help: "Page split") {
            editor.insertDivider(bodyFont: config.font(for: .body))
        }
    }

    @ViewBuilder private var alignmentButtons: some View {
        formatButton("text.alignleft", help: "Align left") { editor.applyAlignment(.left) }
        formatButton("text.aligncenter", help: "Align center") { editor.applyAlignment(.center) }
        formatButton("text.alignright", help: "Align right") { editor.applyAlignment(.right) }
    }

    private func swatchRow(_ colors: [(NSColor, String)],
                           onPick: @escaping (NSColor?) -> Void) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, entry in
                Button {
                    onPick(entry.0)
                } label: {
                    Circle()
                        .fill(Color(nsColor: entry.0))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(NB.hairlineC, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(entry.1)
            }
        }
    }

    private func colorGrid(_ colors: [(NSColor, String)], clearTitle: String?,
                           onPick: @escaping (NSColor?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 7),
                      spacing: 6) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, entry in
                    Button {
                        onPick(entry.0)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: entry.0))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(NB.hairlineC, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(entry.1)
                }
            }
            if let clearTitle {
                Button(action: { onPick(nil) }) {
                    Text(clearTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NB.mutedC)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(NB.fieldC, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(NB.barC)
    }

    private func sizeList(onPick: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.fontSizes, id: \.self) { size in
                Button {
                    editor.applyFontSize(size)
                    onPick()
                } label: {
                    Text("\(Int(size)) pt")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(NB.inkC)
                        .frame(width: 64, alignment: .leading)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(NB.barC)
    }

    private func formatButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        BarButton(symbol: symbol, help: help, action: action)
    }
}

// Borderless bottom-bar glyph: a plain muted icon with a soft hover fill, in
// place of the dark suite's bordered keycap chips.
private struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NB.mutedC)
                .frame(width: 30, height: 28)
                .background(
                    hovering ? NB.hoverC : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    let timeFormatter: DateFormatter
    let density: NotebookListDensity
    let showTimestamp: Bool
    let showPreview: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: density == .compact ? 2 : 4) {
                HStack {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? NB.accentC : NB.inkC)
                        .lineLimit(1)
                    Spacer()
                    if hovering {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(NB.mutedC)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                if showPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 10))
                        .foregroundStyle(NB.mutedC)
                        .lineLimit(density == .compact ? 1 : 2)
                }
                if showTimestamp {
                    Text(timeFormatter.string(from: note.modified).uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .kerning(0.8)
                        .foregroundStyle(NB.faintC)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, density == .compact ? 5 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? NB.selectionC : (hovering ? NB.hoverC : Color.clear),
                in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.animInstant, value: hovering)
        // Selecting a note eases the accent title + fill in, per the grammar's select timing.
        .animation(DS.animBase, value: selected)
    }

    private var preview: String {
        note.plainText
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

// MARK: - Settings pane

private struct NotebookSettingsPane: View {
    @ObservedObject var config: NotebookConfig
    let hotkey: HotkeyPreset
    let onHotkeyChange: (HotkeyPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSettingsCard(title: "Shortcut") {
                HotkeyRecorderButton(
                    label: "Toggle panel", preset: hotkey, onChange: onHotkeyChange)
            }

            DSSettingsCard(title: "Editor") {
                Text("Typeface")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
                HStack(spacing: 8) {
                    ForEach(NotebookFont.allCases, id: \.rawValue) { family in
                        DSChip(title: family.displayName, selected: config.fontFamily == family) {
                            config.fontFamily = family
                        }
                    }
                }
                Text("Base text size")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
                HStack(spacing: 8) {
                    ForEach([11.0, 13.0, 15.0, 17.0, 20.0], id: \.self) { size in
                        DSChip(title: "\(Int(size))", selected: config.fontSize == size) {
                            config.fontSize = size
                        }
                    }
                }
                DSToggleRow(
                    title: "Check spelling while typing",
                    isOn: $config.spellCheck)
                DSToggleRow(
                    title: "Use smart quotes",
                    isOn: $config.smartQuotes)
            }

            // The sidebar is off by default and toggled from the in-app toolbar,
            // so there's no "show sidebar" switch here. Previews, timestamps, and
            // comfortable density are always on — not settings — so this card is
            // just the sidebar's width and sort order.
            DSSettingsCard(title: "Sidebar") {
                Text("Width")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
                HStack(spacing: 8) {
                    ForEach([(180.0, "Narrow"), (210.0, "Standard"), (280.0, "Wide")], id: \.0) { width, title in
                        DSChip(title: title, selected: config.sidebarWidth == width) {
                            config.sidebarWidth = width
                        }
                    }
                }
                Text("Sort notes")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
                HStack(spacing: 8) {
                    ForEach(NotebookSortOrder.allCases, id: \.rawValue) { order in
                        DSChip(title: order.displayName, selected: config.sortOrder == order) {
                            config.sortOrder = order
                        }
                    }
                }
            }

            DSSettingsCard(title: "Window") {
                DSToggleRow(
                    title: "Keep panel on top",
                    caption: "Float above other windows while open.",
                    isOn: $config.floatOnTop)
                Text("Notebook remembers its last size and screen position.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }

            Text("Notes save automatically to Application Support/FreeKit/notes.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dsFaint)
        }
    }
}

// MARK: - Rich text editor

// Formatting commands reach the NSTextView through this proxy so SwiftUI
// toolbar buttons and the AppKit view stay decoupled.
final class RichTextEditorProxy: ObservableObject {
    weak var textView: NSTextView?

    enum HeadingLevel {
        case title, heading, body
    }

    func toggleBold() {
        toggleFontTrait(.bold, mask: .boldFontMask)
    }

    func toggleItalic() {
        toggleFontTrait(.italic, mask: .italicFontMask)
    }

    private func toggleFontTrait(_ trait: NSFontDescriptor.SymbolicTraits,
                                 mask: NSFontTraitMask) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let manager = NSFontManager.shared
        if range.length > 0 {
            // The selection has the trait only if every run does; toggling makes
            // it uniform.
            var allHave = true
            storage.enumerateAttribute(.font, in: range) { value, _, _ in
                let font = value as? NSFont ?? NSFont.systemFont(ofSize: 13)
                if !font.fontDescriptor.symbolicTraits.contains(trait) { allHave = false }
            }
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = value as? NSFont ?? NSFont.systemFont(ofSize: 13)
                let newFont = allHave
                    ? manager.convert(font, toNotHaveTrait: mask)
                    : manager.convert(font, toHaveTrait: mask)
                storage.addAttribute(.font, value: newFont, range: sub)
            }
            storage.endEditing()
            tv.didChangeText()
        } else {
            var attrs = tv.typingAttributes
            let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
            let has = font.fontDescriptor.symbolicTraits.contains(trait)
            attrs[.font] = has
                ? manager.convert(font, toNotHaveTrait: mask)
                : manager.convert(font, toHaveTrait: mask)
            tv.typingAttributes = attrs
        }
    }

    func toggleUnderline() {
        toggleLineStyle(.underlineStyle)
    }

    func toggleStrikethrough() {
        toggleLineStyle(.strikethroughStyle)
    }

    private func toggleLineStyle(_ key: NSAttributedString.Key) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let single = NSUnderlineStyle.single.rawValue
        if range.length > 0 {
            var allHave = true
            storage.enumerateAttribute(key, in: range) { value, _, _ in
                if ((value as? Int) ?? 0) == 0 { allHave = false }
            }
            storage.beginEditing()
            if allHave {
                storage.removeAttribute(key, range: range)
            } else {
                storage.addAttribute(key, value: single, range: range)
            }
            storage.endEditing()
            tv.didChangeText()
        } else {
            var attrs = tv.typingAttributes
            let has = ((attrs[key] as? Int) ?? 0) != 0
            attrs[key] = has ? nil : single
            tv.typingAttributes = attrs
        }
    }

    // Per-selection size keeps each run's family and traits; only points change.
    func applyFontSize(_ size: Double) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let manager = NSFontManager.shared
        if range.length > 0 {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = value as? NSFont ?? NSFont.systemFont(ofSize: 13)
                storage.addAttribute(
                    .font, value: manager.convert(font, toSize: size), range: sub)
            }
            storage.endEditing()
            tv.didChangeText()
        }
        var attrs = tv.typingAttributes
        let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
        attrs[.font] = manager.convert(font, toSize: size)
        tv.typingAttributes = attrs
    }

    // nil clears the highlight.
    func applyHighlight(_ color: NSColor?) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length > 0 {
            if let color {
                storage.addAttribute(.backgroundColor, value: color, range: range)
            } else {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            tv.didChangeText()
        }
        var attrs = tv.typingAttributes
        attrs[.backgroundColor] = color
        tv.typingAttributes = attrs
    }

    func applyAlignment(_ alignment: NSTextAlignment) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let text = storage.string as NSString
        guard storage.length > 0 else {
            setTypingAlignment(alignment, on: tv)
            return
        }
        let range = text.paragraphRange(for: tv.selectedRange())
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
            // Mutate a copy so bullet indents on the same paragraph survive.
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            style.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: style, range: sub)
        }
        storage.endEditing()
        tv.didChangeText()
        setTypingAlignment(alignment, on: tv)
    }

    private func setTypingAlignment(_ alignment: NSTextAlignment, on tv: NSTextView) {
        var attrs = tv.typingAttributes
        let style = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
            as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.alignment = alignment
        attrs[.paragraphStyle] = style
        tv.typingAttributes = attrs
    }

    // Titles/headings apply per paragraph: partial-line headings read as noise.
    func applyHeading(font: NSFont) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let text = storage.string as NSString
        let range = text.paragraphRange(for: tv.selectedRange())
        if range.length > 0 {
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: range)
            storage.endEditing()
            tv.didChangeText()
        }
        var attrs = tv.typingAttributes
        attrs[.font] = font
        tv.typingAttributes = attrs
    }

    func applyColor(_ color: NSColor) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length > 0 {
            storage.addAttribute(.foregroundColor, value: color, range: range)
            tv.didChangeText()
        }
        var attrs = tv.typingAttributes
        attrs[.foregroundColor] = color
        tv.typingAttributes = attrs
    }

    // Page split: a faint full-line rule as literal text, so it survives the
    // RTF round-trip without RTFD attachments.
    // Page split: an empty paragraph carrying a full-width NSTextTableBlock
    // whose only border is a bottom hairline. The block's 100% width tracks the
    // window as it resizes, and table blocks round-trip through RTF.
    func insertDivider(bodyFont: NSFont) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let insertAt = tv.selectedRange().location
        let text = storage.string as NSString
        let atLineStart = insertAt == 0 || text.character(at: insertAt - 1) == 0x0A

        let table = NSTextTable()
        table.numberOfColumns = 1
        let block = NSTextTableBlock(
            table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        block.setBorderColor(NB.divider)
        block.setWidth(0, type: .absoluteValueType, for: .border)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setWidth(3, type: .absoluteValueType, for: .padding)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]

        let divider = NSMutableAttributedString()
        if !atLineStart {
            divider.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        }
        // Tiny font keeps the rule paragraph visually thin.
        divider.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 4),
            .paragraphStyle: style,
        ]))
        storage.insert(divider, at: insertAt)
        tv.setSelectedRange(NSRange(location: insertAt + divider.length, length: 0))
        // Typing after a split starts fresh body text outside the table block.
        var attrs = tv.typingAttributes
        attrs[.font] = bodyFont
        attrs[.foregroundColor] = NB.ink
        attrs[.paragraphStyle] = NotebookConfig.bodyParagraphStyle(fontSize: bodyFont.pointSize)
        tv.typingAttributes = attrs
        tv.didChangeText()
    }

    // Literal "•\t" markers plus a hanging indent: renders as a real list and
    // survives the RTF round-trip as plain content, no NSTextList quirks.
    func toggleBullets() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let text = storage.string as NSString
        let paragraphRange = text.paragraphRange(for: tv.selectedRange())

        var paragraphStarts: [Int] = []
        text.enumerateSubstrings(
            in: paragraphRange, options: [.byParagraphs, .substringNotRequired]
        ) { _, subrange, _, _ in
            paragraphStarts.append(subrange.location)
        }
        if paragraphStarts.isEmpty { paragraphStarts = [paragraphRange.location] }

        let allBulleted = paragraphStarts.allSatisfy { start in
            text.length >= start + 2 && text.substring(with: NSRange(location: start, length: 2)) == "\u{2022}\t"
        }

        storage.beginEditing()
        // Back to front so earlier insertions don't shift later offsets.
        for start in paragraphStarts.reversed() {
            if allBulleted {
                storage.replaceCharacters(in: NSRange(location: start, length: 2), with: "")
            } else {
                let marker = NSAttributedString(
                    string: "\u{2022}\t",
                    attributes: start < storage.length
                        ? storage.attributes(at: start, effectiveRange: nil)
                        : tv.typingAttributes)
                storage.insert(marker, at: start)
            }
        }
        let style = NSMutableParagraphStyle()
        style.headIndent = allBulleted ? 0 : 18
        style.defaultTabInterval = 18
        if let first = paragraphStarts.first {
            // Marker edits shifted everything after the first paragraph start;
            // recompute the affected span before styling it.
            let shift = (allBulleted ? -2 : 2) * paragraphStarts.count
            let end = min(storage.length, paragraphRange.location + paragraphRange.length + shift)
            storage.addAttribute(
                .paragraphStyle, value: style,
                range: NSRange(location: first, length: max(0, end - first)))
        }
        storage.endEditing()
        tv.didChangeText()
    }

    // MARK: - Images

    func insertImageFromPanel() {
        guard let tv = textView else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self, weak tv] response in
            guard response == .OK, let url = panel.url, tv != nil,
                  let image = NSImage(contentsOf: url) else { return }
            self?.insertImage(image)
        }
    }

    func insertImage(_ image: NSImage) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let attachment = RichTextImageSupport.makeAttachment(image: image)
        RichTextImageSupport.scale(attachment, in: tv)
        let attrString = NSAttributedString(attachment: attachment)
        let range = tv.selectedRange()
        storage.replaceCharacters(in: range, with: attrString)
        tv.setSelectedRange(NSRange(location: range.location + attrString.length, length: 0))
        tv.didChangeText()
    }
}

// Image-attachment plumbing shared by the toolbar insert path and the native
// paste/drop path (importsGraphics). Attachments are backed by a PNG file
// wrapper so they survive the RTFD round-trip; plain `.image` alone is dropped
// by RTFD serialization.
enum RichTextImageSupport {
    static func makeAttachment(image: NSImage) -> NSTextAttachment {
        let data = pngData(image) ?? image.tiffRepresentation ?? Data()
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = pngData(image) != nil ? "image.png" : "image.tiff"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.image = image
        return attachment
    }

    // Caps an attachment's on-screen width to the editor's text width, aspect
    // preserved, so a large photo doesn't blow out the note.
    static func scale(_ attachment: NSTextAttachment, in tv: NSTextView) {
        let size = attachmentSize(attachment)
        guard size.width > 0, size.height > 0 else { return }
        let maxWidth = fittingWidth(tv)
        if size.width > maxWidth {
            attachment.bounds = NSRect(
                x: 0, y: 0, width: maxWidth, height: size.height * (maxWidth / size.width))
        } else {
            attachment.bounds = NSRect(origin: .zero, size: size)
        }
    }

    // Re-scales any attachment (e.g. one just pasted/dropped natively) wider than
    // the editor. Returns true if anything changed so callers can reflow.
    @discardableResult
    static func clampOversized(in tv: NSTextView) -> Bool {
        guard let storage = tv.textStorage, storage.length > 0 else { return false }
        let maxWidth = fittingWidth(tv)
        var changed = false
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let size = attachmentSize(attachment)
            guard size.width > maxWidth, size.width > 0, size.height > 0 else { return }
            attachment.bounds = NSRect(
                x: 0, y: 0, width: maxWidth, height: size.height * (maxWidth / size.width))
            tv.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            changed = true
        }
        return changed
    }

    private static func attachmentSize(_ attachment: NSTextAttachment) -> NSSize {
        if attachment.bounds.width > 0, attachment.bounds.height > 0 { return attachment.bounds.size }
        if let image = attachment.image, image.size.width > 0 { return image.size }
        return attachment.attachmentCell?.cellSize() ?? .zero
    }

    private static func fittingWidth(_ tv: NSTextView) -> CGFloat {
        let padding = (tv.textContainer?.lineFragmentPadding ?? 0) * 2
        let width = tv.bounds.width - tv.textContainerInset.width * 2 - padding
        return max(50, width)
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

struct RichTextEditor: NSViewRepresentable {
    @ObservedObject var model: NotebookViewModel
    @ObservedObject var proxy: RichTextEditorProxy

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        let tv = NSTextView(frame: .zero)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.minSize = .zero
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        tv.delegate = context.coordinator
        tv.isRichText = true
        // Accept pasted and dragged-in images as attachments; clamped to width
        // by the coordinator's change/load passes.
        tv.importsGraphics = true
        tv.allowsImageEditing = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        // Transparent so the translucent frosted wash behind the panel reads
        // through the text area, not just the chrome.
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.insertionPointColor = NB.accent
        tv.textContainerInset = NSSize(width: 18, height: 14)
        tv.typingAttributes = model.config.bodyAttributes
        tv.isContinuousSpellCheckingEnabled = model.config.spellCheck
        tv.isAutomaticQuoteSubstitutionEnabled = model.config.smartQuotes
        tv.selectedTextAttributes = [.backgroundColor: NB.selection]
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        proxy.textView = tv
        model.editorTextView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        proxy.textView = coordinator.textView
        model.editorTextView = coordinator.textView
        if let tv = coordinator.textView {
            tv.isContinuousSpellCheckingEnabled = model.config.spellCheck
            tv.isAutomaticQuoteSubstitutionEnabled = model.config.smartQuotes
            if coordinator.fontSize != model.config.fontSize
                || coordinator.fontFamily != model.config.fontFamily {
                tv.typingAttributes = model.config.bodyAttributes
                coordinator.fontSize = model.config.fontSize
                coordinator.fontFamily = model.config.fontFamily
            }
        }
        guard coordinator.loadedGeneration != model.loadGeneration,
              let tv = coordinator.textView else { return }
        coordinator.loadedGeneration = model.loadGeneration
        coordinator.suppressChangeCallback = true
        tv.textStorage?.setAttributedString(model.loadedText)
        if tv.string.isEmpty {
            tv.typingAttributes = model.config.bodyAttributes
        }
        RichTextImageSupport.clampOversized(in: tv)
        coordinator.suppressChangeCallback = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: NotebookViewModel
        weak var textView: NSTextView?
        var loadedGeneration = -1
        var suppressChangeCallback = false
        var fontSize: Double?
        var fontFamily: NotebookFont?

        init(model: NotebookViewModel) {
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressChangeCallback, let tv = textView else { return }
            // A pasted/dropped image lands here at native size; clamp it to width.
            RichTextImageSupport.clampOversized(in: tv)
            model.textDidChange(tv.attributedString())
        }
    }
}
