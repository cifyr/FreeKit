# CLAUDE.md

Guidance for Claude Code (and human contributors) working in this repo.

## What this is

FreeKit is a native macOS menu-bar utility suite, distributed as **FreeSpeech**. It started as a
single-purpose on-device dictation app (hold a hotkey, speak, text lands at the caret) and grew
into a suite of independent tools sharing one app shell, design system, and settings surface. See
`README.md` for the user-facing pitch and `BUILD_SPEC.md` / `DESIGN_BRIEF.md` for historical specs
from earlier feature passes (kept for context, not maintained as living docs).

Swift Package (SPM), two library/executable targets plus a systemLibrary — see `Package.swift`.
macOS 26+, Apple Silicon only (uses on-device `FoundationModels` for optional rewrite passes).

## Module map

Each tool in the suite is a "module": app-side lifecycle in `Sources/FreeSpeech/Modules/<Name>/`,
plus (where the module has real logic worth unit-testing) a pure-Foundation counterpart in
`Sources/FreeSpeechCore/Modules/`. Single source of truth for what modules exist, their catalog
metadata (id, display name, summary, icon, status) is `Sources/FreeSpeechCore/Modules/Shared/ModuleCatalog.swift`.

| Module | Purpose | Core logic |
|---|---|---|
| Speech | The original dictation engine: hotkey → record → whisper.cpp transcribe → post-process → insert at caret. Everything else in the suite grew up around this. | `Sources/FreeSpeechCore/Modules/Speech/` (many files — see below) |
| Notebook | Floating scratch notes on a global hotkey, searchable, saved to disk. | `NotebookStore.swift` |
| Convert | Drag-and-drop file conversion (image/audio/video/doc), on-device. Tool tab (persisted defaults) + App tab (interactive per-file converter). | `ConvertPlan.swift` |
| Clop | Automatic image/video/PDF compression on copy. | `ClopPlan.swift` |
| Shelf | Wiggle-a-drag to park files on a floating shelf, drop them anywhere later. | `ShelfPlan.swift` |
| BoringNotch | Now-playing (Spotify/Apple Music) + next calendar event, docked beside the notch. | — (no extracted pure logic yet) |
| AppCleaner | Uninstall apps together with their leftover support files. | — (no extracted pure logic yet) |
| Autoclick (Tap) | Fixed-interval clicks at the cursor or a set point; supports recorded macros. | `AutoclickPlan.swift`, `Macro.swift` |
| Stats | Live CPU/memory/network/Bluetooth-battery in the menu bar. | `StatsFormatting.swift` |
| CapsLock | Remap Caps Lock to a hyper key, Command, or tap-for-Escape. | `HyperKey.swift` |
| Amphetamine, Cotypist, LinearMouse | Coming-soon placeholders (catalog entry + greyed card only, zero runtime). | `AmphetaminePlan.swift` (others: catalog entry only) |

Adding a module or touching its logic? Start in its `Sources/FreeSpeech/Modules/<Name>/` folder —
that's everything about its window/UI/lifecycle. If it has non-trivial pure logic (formatting,
state machines, plan/config types), that lives in one flat file
`Sources/FreeSpeechCore/Modules/<Name>Plan.swift` (or `<Name>Store.swift` etc. — named for what it
holds, not forced into "Plan") with a matching `Tests/FreeSpeechCoreTests/<Name>PlanTests.swift`.
See `CONTRIBUTING.md` for the full "how to add a module" walkthrough.

## Shared vs per-module code

Three places hold code that isn't owned by a single module:

- **`Sources/FreeSpeech/Shell/`** — app-level infrastructure: `AppDelegate`, `DesignSystem` (the
  whole visual language, `DS`/`ds*` prefix), `AppearanceManager`, `StatusBarController`,
  `Permissions`/`PermissionCoach` (mic/accessibility/camera authorization + guided-grant UI),
  `UpdateManager`. `Sources/FreeSpeech/main.swift` stays at the target root (SPM's top-level-code
  convention) rather than moving into `Shell/`.
- **`Sources/FreeSpeech/Modules/Shared/`** — the module *system* itself: the `AppModule` protocol
  and `ModuleRegistry` (`Module.swift`), the Control Center window that hosts every module's
  settings popup (`ControlCenterWindow.swift`, `ModuleSettingsWindow.swift`), the onboarding-style
  per-module guide sheet (`ModuleGuide.swift`), the shared global hotkey event tap
  (`EventTapHub.swift`, `ShortcutCapture.swift`), the reusable hotkey-recorder control
  (`HotkeyRecorderButton.swift`), cross-module overlay positioning so Shelf/notch/drop-zone panels
  don't stack on each other (`OverlayLayoutCoordinator.swift`), window fade/dismiss animation
  helpers (`PanelFade.swift`), and the suite-wide drag-and-drop entry points that hand a dropped
  file to whichever of Clop/Convert wants it (`SuiteDropZoneCoordinator.swift`,
  `SuiteServiceBridge.swift`, wired to the Finder Services menu).
- **`Sources/FreeSpeechCore/Modules/Shared/`** — its pure-logic counterpart: `ModuleCatalog.swift`
  (the metadata table above, plus the `Settings` extension every module's enabled/menu-bar/hotkey
  state is stored through), `HotkeyRecognizer.swift` (the actual hold/press/chord matching state
  machine), `KeyNames.swift` (key-code → display string), `CoachPlacement.swift` (geometry for the
  permission-coach popup).
- **`Sources/FreeSpeechCore/Settings.swift`** (UserDefaults wrapper) and **`Log.swift`** stay at the
  `FreeSpeechCore` root — they're the foundation everything else, including `Modules/Shared/`,
  builds on, not module-specific themselves.

**Why Speech gets its own `Modules/Speech/` subfolder on both sides, when every other module is a
single flat `<Name>Plan.swift` file:** Speech predates the module system by a long way, so its pure
logic was never one file — it's ten (`DictationStateMachine`, `PostProcessing`, `SmartInsertion`,
`EditLearning`, `SpeakerSplitter`, `SpokenCommands`, `TranscriptCleaner`, `ScreenContext`,
`ModelCatalog`, `HistoryStore`), plus sixteen app-side files (audio capture, the whisper.cpp
engine wrapper, HUD, onboarding, its own settings/history windows, text insertion). A subfolder
was the only sane container; everyone else stays one file because one file is all they need. If a
module ever outgrows a single Core file, give it the same subfolder treatment rather than
splitting it across the `Modules/` root.

**These are folder moves only** (this reorg pass, and going forward): Swift doesn't scope access
by file or folder within one target, so nothing here changes what compiles — the boundaries above
are for humans (who owns what, where to look), not the compiler. Don't rely on folder structure to
enforce module isolation; that's a code-review/PR-ownership convention, not a build guarantee.

## Build & test

```
./build.sh --skip-model   # build + full test suite + assemble dist/FreeKit.app, skip model download
./build.sh                # same, plus fetches the default whisper model on first run
```

**Do not use plain `swift build` / `swift test`** — they compile, but linking fails:
`swift build` doesn't vendor or link the static `whisper.cpp`/`ggml` libraries that `CWhisper`
declares as a system library, so you'll hit "symbol(s) not found for architecture arm64" for every
`whisper_*` symbol. `build.sh` clones/builds `vendor/whisper.cpp` (CMake, Metal) into
`vendor/lib/` first and passes the right linker/include flags — it's the only supported way to
build or test locally. (A fresh checkout also needs the CWhisper headers copied in; `build.sh`
does that too. If you're working from a `git worktree` instead of the primary checkout, the
`vendor/` directory is per-checkout — first build there re-clones/rebuilds whisper.cpp, which is
slow but otherwise safe.)

`build.sh` always installs its result to `/Applications/FreeKit.app` and signs it with the
project's self-signed **"FreeSpeech Dev"** identity — permission grants (Microphone, Accessibility,
Screen Recording, Camera) persist across rebuilds because the signing identity doesn't change.
**Never `tccutil reset` this app** to "fix" a permission issue — that wipes grants for everyone's
local install; scope any defaults/TCC debugging to specific keys, and check with `pgrep FreeKit`
before touching a running instance's UserDefaults or support files.

## Working in this repo generally

- Multiple agent sessions (Claude Code, Codex, etc.) may run concurrently against the same local
  checkout. Git operations (`git add`/`commit`/`reset`) are not isolated between them — a
  concurrent `git reset` can silently drop another session's staged changes. For anything more
  than a quick single-commit change, prefer a dedicated `git worktree` on its own branch over
  working directly in the primary checkout.
- `docs/` is the public GitHub Pages marketing site (`docs/index.html`, `.nojekyll`) — **not** a
  place for engineering docs. Contributor-facing documentation lives at the repo root
  (`CLAUDE.md`, `CONTRIBUTING.md`) and in per-module `README.md` files, not under `docs/`.
