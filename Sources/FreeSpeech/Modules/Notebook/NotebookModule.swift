import AppKit
import Combine
import SwiftUI
import FreeSpeechCore

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
    private lazy var settingsWindow = ModuleSettingsWindowController(info: info) { [weak self] in
        self?.makeSettingsPane() ?? AnyView(EmptyView())
    }

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

    func openSettings() {
        settingsWindow.show()
    }

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

enum NotebookFont: String, CaseIterable {
    case system, serif, mono

    var displayName: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .mono: return "Mono"
        }
    }
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

    init(settings: Settings) {
        self.settings = settings
        fontSize = settings.moduleDouble(id: id, key: "fontSize") ?? 13
        fontFamily = settings.moduleString(id: id, key: "fontFamily")
            .flatMap(NotebookFont.init) ?? .system
        sidebarVisible = settings.moduleBool(id: id, key: "sidebarVisible") ?? true
        floatOnTop = settings.moduleBool(id: id, key: "floatOnTop") ?? true
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

    var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font(size: fontSize),
            .foregroundColor: DS.paper,
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
        if let id { model.select(id) }
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
        panel?.orderOut(nil)
    }

    private func focus() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.focusEditor()
    }

    private func buildIfNeeded() {
        guard panel == nil else { return }
        let hosting = NSHostingController(rootView: NotebookView(model: model, config: config))
        // A titled, floating panel: stays over normal windows for quick capture
        // but never joins all Spaces or steals full-screen focus.
        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView]
        p.title = "Notebook"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = DS.ink0
        p.level = config.floatOnTop ? .floating : .normal
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 480, height: 340)
        p.setContentSize(NSSize(width: 680, height: 440))
        p.center()
        panel = p
        floatCancellable = config.$floatOnTop.sink { [weak p] onTop in
            p?.level = onTop ? .floating : .normal
        }
    }
}

// MARK: - View model

final class NotebookViewModel: ObservableObject {
    @Published var query: String = "" { didSet { refresh() } }
    @Published private(set) var notes: [Note] = []
    @Published var selectedID: UUID?
    // Bumped when the editor must reload its content (selection change).
    @Published private(set) var loadGeneration = 0
    private(set) var loadedText = NSAttributedString()
    weak var editorTextView: NSTextView?

    private let store: NotebookStore
    let config: NotebookConfig
    let openSettings: () -> Void
    private var saveTimer: Timer?
    private var pendingSave: (id: UUID, text: NSAttributedString)?

    init(store: NotebookStore, config: NotebookConfig, openSettings: @escaping () -> Void) {
        self.store = store
        self.config = config
        self.openSettings = openSettings
        refresh()
    }

    func refresh() {
        notes = store.search(query)
    }

    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let tv = self?.editorTextView else { return }
            tv.window?.makeFirstResponder(tv)
        }
    }

    func select(_ id: UUID) {
        flushPendingSave()
        guard let note = store.note(id: id) else { return }
        selectedID = id
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
            loadedText = NSAttributedString()
            loadGeneration += 1
        }
        refresh()
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
        guard let (id, text) = pendingSave else { return }
        pendingSave = nil
        guard var note = store.note(id: id) else { return }
        let plain = text.string
        let firstLine = plain.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        note.title = String(firstLine.prefix(60))
        note.plainText = plain
        note.rich = text.rtf(
            from: NSRange(location: 0, length: text.length), documentAttributes: [:])
        note.modified = Date()
        store.upsert(note)
    }

    private func attributedText(from note: Note) -> NSAttributedString {
        if let rich = note.rich,
           let text = NSAttributedString(rtf: rich, documentAttributes: nil) {
            return text
        }
        return NSAttributedString(string: note.plainText, attributes: config.bodyAttributes)
    }
}

// MARK: - Views

struct NotebookView: View {
    @ObservedObject var model: NotebookViewModel
    @ObservedObject var config: NotebookConfig
    @StateObject private var editor = RichTextEditorProxy()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            if config.sidebarVisible {
                sidebar
                Rectangle().fill(Color.dsLine).frame(width: 1)
            }

            VStack(alignment: .leading, spacing: 0) {
                toolbar
                Rectangle().fill(Color.dsLine).frame(height: 1)
                RichTextEditor(model: model, proxy: editor)
            }
        }
        .background(Color.dsInk0)
        .frame(minWidth: 480, minHeight: 340)
        .animation(.easeOut(duration: DS.durBase), value: config.sidebarVisible)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dsFaint)
                TextField("Search notes", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dsPaper)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                Color.dsInk2,
                in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                    .strokeBorder(Color.dsLine, lineWidth: 1))

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.notes) { note in
                        NoteRow(
                            note: note,
                            selected: model.selectedID == note.id,
                            timeFormatter: Self.timeFormatter,
                            onSelect: { model.select(note.id) },
                            onDelete: { model.delete(note.id) })
                    }
                }
            }

            Button("New Note") { model.newNote() }
                .buttonStyle(GhostButtonStyle())
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 210)
    }

    // Content colors are user data, not interface chrome, so the palette here
    // deliberately goes beyond the DS accent (Google-Docs-style choice).
    private static let textColors: [(NSColor, String)] = [
        (DS.paper, "Paper"), (DS.muted, "Muted"), (.systemGray, "Gray"),
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

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                formatButton("sidebar.left", help: config.sidebarVisible ? "Hide sidebar" : "Show sidebar") {
                    config.sidebarVisible.toggle()
                }
                Rectangle().fill(Color.dsLine).frame(width: 1, height: 16)
                formatButton("textformat.size.larger", help: "Title") {
                    editor.applyHeading(font: config.font(for: .title))
                }
                formatButton("textformat.size", help: "Heading") {
                    editor.applyHeading(font: config.font(for: .heading))
                }
                formatButton("textformat", help: "Body text") {
                    editor.applyHeading(font: config.font(for: .body))
                }
                Rectangle().fill(Color.dsLine).frame(width: 1, height: 16)
                formatButton("bold", help: "Bold") { editor.toggleBold() }
                formatButton("italic", help: "Italic") { editor.toggleItalic() }
                formatButton("underline", help: "Underline") { editor.toggleUnderline() }
                formatButton("strikethrough", help: "Strikethrough") { editor.toggleStrikethrough() }
                Spacer()
                formatButton("gearshape", help: "Notebook settings") { model.openSettings() }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            HStack(spacing: 6) {
                formatButton("paintbrush.pointed", help: "Text color") { showTextColors.toggle() }
                    .popover(isPresented: $showTextColors, arrowEdge: .bottom) {
                        colorGrid(Self.textColors, clearTitle: nil) { color in
                            editor.applyColor(color ?? DS.paper)
                        }
                    }
                formatButton("highlighter", help: "Highlight") { showHighlights.toggle() }
                    .popover(isPresented: $showHighlights, arrowEdge: .bottom) {
                        colorGrid(Self.highlightColors, clearTitle: "None") { color in
                            editor.applyHighlight(color)
                        }
                    }
                formatButton("textformat.size.smaller", help: "Text size") { showSizes.toggle() }
                    .popover(isPresented: $showSizes, arrowEdge: .bottom) {
                        sizeGrid
                    }
                Rectangle().fill(Color.dsLine).frame(width: 1, height: 16)
                formatButton("list.bullet", help: "Bullet list") { editor.toggleBullets() }
                formatButton("rectangle.split.1x2", help: "Page split") {
                    editor.insertDivider(bodyFont: config.font(for: .body))
                }
                Rectangle().fill(Color.dsLine).frame(width: 1, height: 16)
                formatButton("text.alignleft", help: "Align left") { editor.applyAlignment(.left) }
                formatButton("text.aligncenter", help: "Align center") { editor.applyAlignment(.center) }
                formatButton("text.alignright", help: "Align right") { editor.applyAlignment(.right) }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
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
                            .overlay(Circle().strokeBorder(Color.dsLine, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(entry.1)
                }
            }
            if let clearTitle {
                Button(clearTitle) { onPick(nil) }
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(12)
        .background(Color.dsInk1)
    }

    private var sizeGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.fontSizes, id: \.self) { size in
                Button {
                    editor.applyFontSize(size)
                    showSizes = false
                } label: {
                    Text("\(Int(size)) pt")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.dsPaper)
                        .frame(width: 64, alignment: .leading)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.dsInk1)
    }

    private func formatButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
                .frame(width: 28, height: 26)
                .background(
                    Color.dsInk2,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.dsLine, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

}

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    let timeFormatter: DateFormatter
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color.dsAccent : Color.dsPaper)
                        .lineLimit(1)
                    Spacer()
                    if hovering {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.dsMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(timeFormatter.string(from: note.modified).uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(Color.dsFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.dsInk2 : (hovering ? Color.dsInk1 : Color.clear),
                in: RoundedRectangle(cornerRadius: DS.radiusKeycap, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Settings pane

private struct NotebookSettingsPane: View {
    @ObservedObject var config: NotebookConfig
    let hotkey: HotkeyPreset
    let onHotkeyChange: (HotkeyPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HotkeyRecorderButton(label: "Toggle panel", preset: hotkey, onChange: onHotkeyChange)

            VStack(alignment: .leading, spacing: 8) {
                DSSectionLabel("Font")
                HStack(spacing: 8) {
                    ForEach(NotebookFont.allCases, id: \.rawValue) { family in
                        DSChip(title: family.displayName, selected: config.fontFamily == family) {
                            config.fontFamily = family
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                DSSectionLabel("Text size")
                HStack(spacing: 8) {
                    ForEach([11.0, 13.0, 15.0, 17.0], id: \.self) { size in
                        DSChip(title: "\(Int(size)) pt", selected: config.fontSize == size) {
                            config.fontSize = size
                        }
                    }
                    DSNumberField(
                        placeholder: "pt",
                        value: $config.fontSize,
                        range: 9...32,
                        fractionDigits: 0,
                        onCommit: { config.fontSize = $0 })
                }
                Text("Applies to new text; existing notes keep their styling.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsFaint)
            }

            VStack(alignment: .leading, spacing: 10) {
                DSSectionLabel("Panel")
                DSToggleRow(
                    title: "Show sidebar",
                    caption: "Note list and search. Also toggleable from the toolbar.",
                    isOn: $config.sidebarVisible)
                DSToggleRow(
                    title: "Keep panel on top",
                    caption: "Float above other windows while open.",
                    isOn: $config.floatOnTop)
            }

            Text("Notes save automatically to Application Support/FreeSpeech/notes.")
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
    func insertDivider(bodyFont: NSFont) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let insertAt = tv.selectedRange().location
        let text = storage.string as NSString
        let atLineStart = insertAt == 0 || text.character(at: insertAt - 1) == 0x0A
        let rule = String(repeating: "\u{2500}", count: 32)
        let divider = NSMutableAttributedString(
            string: (atLineStart ? "" : "\n") + rule + "\n",
            attributes: [
                .font: bodyFont,
                .foregroundColor: DS.faint,
            ])
        storage.insert(divider, at: insertAt)
        tv.setSelectedRange(NSRange(location: insertAt + divider.length, length: 0))
        // Typing after a split starts fresh body text, not faint rule styling.
        var attrs = tv.typingAttributes
        attrs[.font] = bodyFont
        attrs[.foregroundColor] = DS.paper
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
}

struct RichTextEditor: NSViewRepresentable {
    @ObservedObject var model: NotebookViewModel
    @ObservedObject var proxy: RichTextEditorProxy

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.drawsBackground = true
        tv.backgroundColor = DS.ink0
        tv.insertionPointColor = DS.accent
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.typingAttributes = model.config.bodyAttributes
        tv.selectedTextAttributes = [.backgroundColor: DS.ink3]
        scroll.drawsBackground = true
        scroll.backgroundColor = DS.ink0
        proxy.textView = tv
        model.editorTextView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        proxy.textView = coordinator.textView
        model.editorTextView = coordinator.textView
        guard coordinator.loadedGeneration != model.loadGeneration,
              let tv = coordinator.textView else { return }
        coordinator.loadedGeneration = model.loadGeneration
        coordinator.suppressChangeCallback = true
        tv.textStorage?.setAttributedString(model.loadedText)
        if tv.string.isEmpty {
            tv.typingAttributes = model.config.bodyAttributes
        }
        coordinator.suppressChangeCallback = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: NotebookViewModel
        weak var textView: NSTextView?
        var loadedGeneration = -1
        var suppressChangeCallback = false

        init(model: NotebookViewModel) {
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressChangeCallback, let tv = textView else { return }
            model.textDidChange(tv.attributedString())
        }
    }
}
