# Contributing

This is a solo-built project opened up here for anyone picking up a piece of it. This doc is the
architecture tour and the "how do I add a module" recipe. For the file-layout map and build
gotchas, see `CLAUDE.md` first.

## Architecture in one paragraph

`main.swift` builds an `NSApplication` with `AppDelegate` (`Sources/FreeSpeech/Shell/`) as the
composition root. `AppDelegate` owns one `Settings` (UserDefaults wrapper), one `EventTapHub`
(the single global `CGEventTap` every module's hotkeys share — only one process can own a given
tap, so modules never make their own), and one `ModuleRegistry`. Every tool constructs itself as
an `AppModule` and gets handed to `registry.register(...)`; the registry reads persisted
enabled/menu-bar-item state from `Settings` and calls `activate()`/`deactivate()` accordingly, live,
with no relaunch needed when a user flips a toggle in Control Center.

## The module contract

`AppModule` (`Sources/FreeSpeech/Modules/Shared/Module.swift`) is the whole interface:

```swift
protocol AppModule: AnyObject {
    var info: ModuleInfo { get }              // catalog metadata: id, name, summary, icon, status
    func activate()                            // construct + wire up runtime state (lazy: an
    func deactivate()                          // an unused module should cost ~nothing at launch)
    func setMenuBarItemVisible(_ visible: Bool) // only called if info.ownsMenuBarItem
    var settingsStyle: ModuleSettingsStyle { get }     // .popup / .inline / .none
    var settingsPopupSize: NSSize { get }
    var popupUsesOwnChrome: Bool { get }
    func makeSettingsPane() -> AnyView
    func openSettings()
}
```

`ModuleInfo` (`Sources/FreeSpeechCore/Modules/Shared/ModuleCatalog.swift`) is the pure-data half:
id, display name, one-line summary, SF Symbol name, `.available`/`.comingSoon` status, and whether
the module owns its own persistent menu-bar item (vs. "app"-style tools like Convert/AppCleaner/Tap
that self-manage a status item only while open — see `ModuleCatalog.apps`).

## Adding a new module

1. **Catalog entry** — add a `ModuleInfo` to `ModuleCatalog.swift` and to `ModuleCatalog.all` (and
   to `.apps` if it's an app-style tool rather than an always-on menu-bar utility). Pick a stable
   `id` — it's the UserDefaults key prefix (`module.<id>.*`) forever after.
2. **Pure logic (optional)** — if the module has non-trivial deterministic logic (state machines,
   formatting, parsing, a config/plan type), write it in `FreeSpeechCore` so it's unit-testable
   without linking AppKit or whisper: one file, `Sources/FreeSpeechCore/Modules/<Name>Plan.swift`
   (name it for what it holds — `Plan`, `Store`, whatever reads naturally), tests in
   `Tests/FreeSpeechCoreTests/<Name>PlanTests.swift`. Skip this if the module is simple enough that
   its app-side class is the whole implementation (see AppCleaner, BoringNotch).
3. **App-side implementation** — new folder `Sources/FreeSpeech/Modules/<Name>/`, a class
   conforming to `AppModule`. Look at `Sources/FreeSpeech/Modules/Shelf/ShelfModule.swift` for a
   compact real example (settings pane, panel lifecycle, persisted per-module keys) or
   `Sources/FreeSpeech/Modules/Convert/` for a bigger one (multiple files, its own toast/drop-zone
   UI).
4. **Register it** — construct it and call `registry.register(...)` in
   `Sources/FreeSpeech/Shell/AppDelegate.swift:applicationDidFinishLaunching`. If it needs global
   hotkeys, take the shared `eventHub`; if it needs to react to permission state, take the shared
   `permissionCoach`.
5. **Settings storage** — don't invent a new persistence mechanism. Use the generic per-module
   accessors on `Settings` (`moduleBool`, `moduleString`, `moduleDouble`, `moduleInt`,
   `moduleHotkey`, all namespaced by your module's `id`) added by the `ModuleCatalog.swift`
   extension.
6. **Build/test**: `./build.sh --skip-model` (see `CLAUDE.md` for why not plain `swift build`).

## Conventions worth keeping

- **One module, one folder, one owner.** Everything about a module's UI/lifecycle lives under its
  `Sources/FreeSpeech/Modules/<Name>/` folder; nothing else in the app should reach into a
  module's internals — go through `AppModule`/`ModuleRegistry`, or through the shared
  coordinators in `Modules/Shared/` (`OverlayLayoutCoordinator`, `SuiteDropZoneCoordinator`) if two
  modules genuinely need to interact (e.g. a dropped file that could go to either Clop or Convert).
  This is what makes it safe for different people to own different modules without touching each
  other's files in the same PR.
- **Swift access control doesn't enforce any of this** — `FreeSpeech` and `FreeSpeechCore` are each
  one target, so everything in a target is visible to everything else in it. The module boundary
  is a convention (folder ownership + `AppModule`/`ModuleRegistry` as the only sanctioned
  cross-module surface), not a compiler guarantee. Code review is where this actually gets
  enforced — if a PR for one module starts editing files under a different module's folder (other
  than the one `registry.register(...)` line in `AppDelegate.swift`, or a genuine shared
  coordinator in `Modules/Shared/`), that's worth a second look.
- **Deterministic logic goes in `FreeSpeechCore`, not the app target.** Anything you'd want to unit
  test without spinning up AppKit/whisper belongs there — it's what keeps `Tests/` fast (currently
  254 tests, sub-second) and independent of signing/permissions/hardware.
- **Don't add a new global event tap.** macOS only lets one process hold a given tap reliably;
  every module's hotkey goes through the shared `EventTapHub` (`Modules/Shared/EventTapHub.swift`)
  and the `HotkeyRecognizer` state machine, not a fresh `CGEvent.tapCreate`.
- **Panels that should float over full-screen apps** need `collectionBehavior` including
  `.fullScreenAuxiliary` (and usually `.canJoinAllSpaces`), on top of an elevated `.level`. Easy to
  forget — several existing panels shipped without it and had to be fixed later. Grep
  `collectionBehavior` for the current examples before adding a new floating panel.
- **This is a real app people run daily.** Prefer additive changes and `git mv`-preserved
  reorganization over rewrites; don't change behavior in the same PR as a structural move.

## Where to look for module-specific detail

Each module folder under `Sources/FreeSpeech/Modules/` has a short `README.md` pointing at its
entry point, its `FreeSpeechCore` counterpart (if any), and anything non-obvious about it. Start
there rather than reading the whole module's source when you're picking up a specific piece.
