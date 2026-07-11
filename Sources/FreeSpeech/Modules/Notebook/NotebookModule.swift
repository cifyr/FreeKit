import AppKit
import SwiftUI
import FreeSpeechCore

// Notebook: a floating note panel toggled by a global hotkey. Notes persist as
// RTF (round-trips bold/color/bullets and stays readable by other apps) with a
// plain-text shadow for search, one file per note via NotebookStore.
final class NotebookModule: NSObject, AppModule, NSMenuDelegate {
    let info = ModuleCatalog.notebook

    private let settings: Settings
    private let hub: EventTapHub
    private var store: NotebookStore?
    private var hotkeyToken: EventTapHub.HotkeyToken?
    private var statusItem: NSStatusItem?
    private var panel: NotebookPanelController?

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
        if panel == nil {
            panel = NotebookPanelController(store: store)
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

    func makeSettingsPane() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            HotkeyRecorderButton(
                label: "Toggle panel", preset: hotkey,
                onChange: { [weak self] preset in
                    guard let self else { return }
                    self.settings.setModuleHotkey(preset, id: self.info.id)
                    if let token = self.hotkeyToken {
                        self.hub.update(token, preset: preset)
                    }
                })
            Text("Notes save automatically to Application Support/FreeSpeech/notes.")
                .font(.system(size: 11))
                .foregroundStyle(Color.dsFaint)
        })
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let newNote = NSMenuItem(
            title: "New Note", action: #selector(newNote), keyEquivalent: "")
        newNote.target = self
        menu.addItem(newNote)
        let open = NSMenuItem(
            title: "Open Notebook", action: #selector(openNotebook), keyEquivalent: "")
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
    }

    @objc private func newNote() {
        panel?.showNewNote()
    }

    @objc private func openNotebook() {
        panel?.show()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        panel?.show(selecting: id)
    }
}

// MARK: - Panel

final class NotebookPanelController {
    private var panel: NSPanel?
    private let model: NotebookViewModel

    init(store: NotebookStore) {
        model = NotebookViewModel(store: store)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show(selecting id: UUID? = nil) {
        buildIfNeeded()
        model.refresh()
        if let id { model.select(id) }
        if model.selectedID == nil { model.selectFirstOrCreate() }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showNewNote() {
        buildIfNeeded()
        model.refresh()
        model.newNote()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        model.flushPendingSave()
        panel?.orderOut(nil)
    }

    private func buildIfNeeded() {
        guard panel == nil else { return }
        let hosting = NSHostingController(rootView: NotebookView(model: model))
        // A titled, floating panel: stays over normal windows for quick capture
        // but never joins all Spaces or steals full-screen focus.
        let p = NSPanel(contentViewController: hosting)
        p.styleMask = [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView]
        p.title = "Notebook"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = DS.ink0
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 560, height: 340)
        p.setContentSize(NSSize(width: 660, height: 420))
        p.center()
        panel = p
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

    private let store: NotebookStore
    private var saveTimer: Timer?
    private var pendingSave: (id: UUID, text: NSAttributedString)?

    // The resting text color is paper on ink; RTF stores it explicitly so notes
    // reopen looking exactly as written.
    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: DS.paper,
    ]

    init(store: NotebookStore) {
        self.store = store
        refresh()
    }

    func refresh() {
        notes = store.search(query)
    }

    func select(_ id: UUID) {
        flushPendingSave()
        guard let note = store.note(id: id) else { return }
        selectedID = id
        loadedText = Self.attributedText(from: note)
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

    private static func attributedText(from note: Note) -> NSAttributedString {
        if let rich = note.rich,
           let text = NSAttributedString(rtf: rich, documentAttributes: nil) {
            return text
        }
        return NSAttributedString(string: note.plainText, attributes: baseAttributes)
    }
}

// MARK: - Views

struct NotebookView: View {
    @ObservedObject var model: NotebookViewModel
    @StateObject private var editor = RichTextEditorProxy()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
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

            Rectangle().fill(Color.dsLine).frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    formatButton("bold", help: "Bold") { editor.toggleBold() }
                    formatButton("list.bullet", help: "Bullet list") { editor.toggleBullets() }
                    Rectangle().fill(Color.dsLine).frame(width: 1, height: 16)
                    colorSwatch(DS.paper, name: "Paper")
                    colorSwatch(DS.accent, name: "Red")
                    colorSwatch(DS.muted, name: "Muted")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                Rectangle().fill(Color.dsLine).frame(height: 1)
                RichTextEditor(model: model, proxy: editor)
            }
        }
        .background(Color.dsInk0)
        .frame(minWidth: 560, minHeight: 340)
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

    private func colorSwatch(_ color: NSColor, name: String) -> some View {
        Button {
            editor.applyColor(color)
        } label: {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Color.dsLine, lineWidth: 1))
                .frame(width: 24, height: 26)
        }
        .buttonStyle(.plain)
        .help("Text color: \(name)")
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

// MARK: - Rich text editor

// Formatting commands reach the NSTextView through this proxy so SwiftUI
// toolbar buttons and the AppKit view stay decoupled.
final class RichTextEditorProxy: ObservableObject {
    weak var textView: NSTextView?

    func toggleBold() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let manager = NSFontManager.shared
        if range.length > 0 {
            // The selection is bold only if every run is; toggling makes it uniform.
            var allBold = true
            storage.enumerateAttribute(.font, in: range) { value, _, _ in
                let font = value as? NSFont ?? NSFont.systemFont(ofSize: 13)
                if !font.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
            }
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = value as? NSFont ?? NSFont.systemFont(ofSize: 13)
                let newFont = allBold
                    ? manager.convert(font, toNotHaveTrait: .boldFontMask)
                    : manager.convert(font, toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: newFont, range: sub)
            }
            storage.endEditing()
            tv.didChangeText()
        } else {
            var attrs = tv.typingAttributes
            let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
            let isBold = font.fontDescriptor.symbolicTraits.contains(.bold)
            attrs[.font] = isBold
                ? manager.convert(font, toNotHaveTrait: .boldFontMask)
                : manager.convert(font, toHaveTrait: .boldFontMask)
            tv.typingAttributes = attrs
        }
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
        tv.typingAttributes = NotebookViewModel.baseAttributes
        tv.selectedTextAttributes = [.backgroundColor: DS.ink3]
        scroll.drawsBackground = true
        scroll.backgroundColor = DS.ink0
        proxy.textView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        proxy.textView = coordinator.textView
        guard coordinator.loadedGeneration != model.loadGeneration,
              let tv = coordinator.textView else { return }
        coordinator.loadedGeneration = model.loadGeneration
        coordinator.suppressChangeCallback = true
        tv.textStorage?.setAttributedString(model.loadedText)
        if tv.string.isEmpty {
            tv.typingAttributes = NotebookViewModel.baseAttributes
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
