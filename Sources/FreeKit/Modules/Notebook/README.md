# Notebook

Floating scratch-note panel on a global hotkey — quick capture, searchable, persisted to disk.

**Entry point:** `NotebookModule.swift` (also defines the panel controller and view model in the
same file — small enough not to need splitting yet).

**Core logic:** `Sources/FreeKitCore/Modules/NotebookStore.swift`.

**Gotcha:** the panel's `floatOnTop` config toggle drives both `NSWindow.level` and
`collectionBehavior` (`.canJoinAllSpaces, .fullScreenAuxiliary`) together — if you add another
place that changes one, change both, or the panel will float above normal windows but still
vanish behind another app's full-screen Space (or vice versa).
