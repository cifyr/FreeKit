# /goal

On branch `feat/clop`, the FreeKit suite's greyed-out **Clop** card becomes a working module: a
clipboard-watching compressor that, when enabled, notices freshly copied images (and optionally
videos and PDFs), re-encodes them smaller on-device, and puts the smaller version back on the
clipboard — plus a manual "optimize these files" path. It follows every existing module pattern
(registry entry, own menu-bar item with live pause/status, its own settings window built from the
shared DS components, per-module Settings keys, pure decision logic in FreeSpeechCore with tests).
`swift test` (all current tests plus new Clop tests) and `./build.sh --skip-model` pass; work is
committed on `feat/clop` with an explicit file list, NOT merged, NOT pushed — the user will try it
and merge. Motivation: this is a daily-driver utility on a personal Mac — when a detail is
unspecified, favor "never lose the user's data and never surprise them" over aggressive compression.

## Definition of done

- [ ] `ModuleCatalog.clop` flips to `.available`; the control-center card gains the standard ON /
      MENU BAR toggles and a gear opening a Clop settings window
- [ ] `ClopModule` registered in `AppDelegate` in place of its `PlaceholderModule` line; enabling
      and disabling it live-adds/removes its `NSStatusItem` with no relaunch, and it defaults OFF
- [ ] With the module on and watching: copying an image (raw image data or a file URL to a
      png/jpeg/heic/tiff/gif) results in a smaller encoded version replacing the clipboard contents
      within ~1s, and the original is restorable via "Undo Last Optimization"
- [ ] The "only if smaller" rule always holds: if re-encoding does not shrink the payload (past the
      configured minimum-savings threshold), the clipboard is left untouched and the menu says so
- [ ] File optimization works: menu item "Optimize Files…" (NSOpenPanel, multi-select) writes
      results per the replace/alongside setting; replaced originals are backed up under
      `Application Support/FreeSpeech/clop-backups/` before being overwritten
- [ ] Video (AVAssetExportSession) and PDF (PDFKit write with image optimization) paths work for the
      file-optimization flow; clipboard watching for them is toggleable and defaults OFF (videos on
      the pasteboard are rare and exports are slow — do them async with menu-bar progress)
- [ ] Menu-bar item: distinct icon states for watching / paused / working; menu shows last result
      ("Saved 1.2 MB (64%)"), Pause/Resume Watching, Optimize Clipboard Now, Optimize Files…, Undo
      Last Optimization, Clop Settings…  (NO Quit item — suite-wide rule)
- [ ] Settings window (via `ModuleSettingsWindowController`, `DSSettingsCard` sections): per-type
      enable (images / videos / PDFs), image quality chips + custom `DSNumberField`, max-dimension
      downscale (off / 1440 / 2160 / 3840 / custom), output format policy (keep format vs convert
      to JPEG/HEIC), minimum savings %, skip-below-size KB, replace-vs-alongside for files, and an
      optional global hotkey (via `HotkeyRecorderButton` + `EventTapHub`) for Optimize Clipboard Now
- [ ] Pure decision logic lives in `Sources/FreeSpeechCore/Modules/ClopPlan.swift` and is tested:
      should-process decision (type enabled, size floor, pasteboard-change dedupe), target-dimension
      math (aspect-preserving fit to max dimension, never upscale), keep-if-smaller/min-savings
      rule, savings formatting, backup and "(clopped)" sibling filename derivation
- [ ] All existing tests still pass; `swift test $(for l in vendor/lib/*.a; do echo -Xlinker $l; done)`
      and `./build.sh --skip-model` are green
- [ ] No emojis anywhere; comments explain *why* only; committed on `feat/clop` with an explicit
      file list; NOT merged; NOT pushed

## Read first

1. `/Users/caden/.claude/CLAUDE.md` — global working rules (branching, commits, archive-not-rm,
   logging style, testing, no emojis). Load-bearing.
2. The module pattern, in this order — Clop must be indistinguishable in style from these:
   - `Sources/FreeSpeech/Modules/Module.swift` — `AppModule` protocol, `ModuleRegistry`,
     `ModuleSettingsStyle`
   - `Sources/FreeSpeechCore/Modules/ModuleCatalog.swift` — catalog entry + per-module Settings
     accessors (`moduleBool/Double/Int/String`, `moduleHotkey`)
   - `Sources/FreeSpeech/Modules/Autoclick/AutoclickModule.swift` — the richest existing module:
     status item with state icon, menu, settings window, hotkey registration, Core-plan usage
   - `Sources/FreeSpeech/Modules/ModuleSettingsWindow.swift` — settings window shell +
     `DSSettingsCard` / `DSToggleRow` / `DSNumberField` / `DSSectionLabel`
   - `Sources/FreeSpeech/Modules/EventTapHub.swift` — how global hotkeys are registered
   - `Sources/FreeSpeechCore/Modules/AutoclickPlan.swift` + its tests — the Core-logic + test idiom
3. `Sources/FreeSpeech/AppDelegate.swift` — where modules are registered (Clop is currently in the
   `PlaceholderModule` loop near the bottom of the registration block).

## Context: what exists

- Swift Package Manager app, macOS 26 target. `FreeSpeechCore` is pure Foundation (testable, no
  AppKit); `FreeSpeech` is the app target (AppKit/SwiftUI, links AVFoundation already). Tests run
  with whisper static libs linked: `swift test $(for l in vendor/lib/*.a; do echo -Xlinker $l; done)`.
- The suite ("FreeKit", executable/bundle still FreeSpeech/com.cadenwarren.freespeech, self-signed
  "FreeSpeech Dev" — TCC grants depend on both) is a Dock app; modules own optional menu-bar items.
  `./build.sh --skip-model` runs tests, builds, signs, and installs to `/Applications/FreeSpeech.app`.
- `ModuleCatalog.clop` already exists (`id: "clop"`, symbol `rectangle.compress.vertical`,
  `status: .comingSoon`, `ownsMenuBarItem: true`) and renders as a greyed card.
- Design system: Greenlight-red tokens in `DesignSystem.swift` (`dsInk0–3`, `dsLine`, `dsPaper`,
  `dsMuted`, `dsFaint`, `dsAccent`), dark-only. Reuse `DSChip`, `GhostButtonStyle`, the DS settings
  components. Accent red means "live activity" (see Tap's active icon tint).
- Clipboard: there is no pasteboard-change notification API — poll `NSPasteboard.general.changeCount`
  on a timer (~0.5s) while watching, and remember the changeCount you wrote yourself so Clop never
  re-processes its own output (loop guard — put this dedupe decision in Core so it's tested).
- No new permissions are needed: pasteboard access is free; file access flows through the user's
  NSOpenPanel selection.

## Hard constraints / do not

- Do NOT change the bundle identifier, executable name, or signing identity, and never reset TCC.
- Do NOT add any network calls or telemetry — everything on-device (this rules out any cloud
  optimizers; use ImageIO/CoreGraphics, AVFoundation, PDFKit only).
- Never destroy user data: file replacement always writes the backup first (atomic: back up, write
  to temp, swap); clipboard optimization always snapshots the prior contents for Undo. Whole-file
  deletions in the repo go to `.archive/<UTC-timestamp>/…`, never `rm`.
- Do NOT introduce new colors, UI frameworks, or SPM targets/dependencies.
- Do NOT touch other modules' behavior; the only shared-file edits are the one-line catalog status
  flip and the AppDelegate registration swap.
- No per-tool Quit menu item. No emojis. Comments explain why, never what.
- Another working session may be editing this repo concurrently. If `swift build`/`build.sh` fails
  with "input file was modified during the build", just retry; rebase around uncommitted changes you
  did not make and never revert or commit files you did not touch.
- Commit once at the end (all tests green) with an explicit file list; do NOT merge or push.

## Task spec

### 1. Core logic — `Sources/FreeSpeechCore/Modules/ClopPlan.swift`

A pure decision layer the app target consumes (mirror `AutoclickPlan`'s style):

- `ClopSettingsSnapshot`-style value type (or plain parameters) capturing: images/videos/PDFs
  enabled, quality (0–1), max dimension (nil = no downscale), convert-to format policy, minimum
  savings fraction (default 0.10), skip-below bytes (default 10 KB), replace vs alongside.
- `shouldProcess(type:byteCount:isOwnWrite:)` — the gate, including the own-write dedupe.
- `targetSize(width:height:maxDimension:)` — aspect-preserving fit, never upscales.
- `keepResult(originalBytes:optimizedBytes:minimumSavings:)` — the only-if-smaller rule.
- Filename helpers: `sibling(for: URL)` → `photo (clopped).jpg` next to the original (dedupe with
  `(clopped 2)` if taken), and `backupURL(for: URL, in: directory)` preserving the filename.
- Savings summary formatting ("Saved 1.2 MB (64%)") — reuse `StatsFormatting.bytes`.
- Unit tests for all of the above in `Tests/FreeSpeechCoreTests/ClopPlanTests.swift`.

### 2. Encoders — app target, `Sources/FreeSpeech/Modules/Clop/`

- **Images** (`ImageIO`/CoreGraphics): decode, downscale to the plan's target size
  (`CGImageSourceCreateThumbnailAtIndex` is fine), re-encode per policy — JPEG or HEIC with the
  configured quality; PNGs convert per the format policy (keep-PNG means recompress via ImageIO
  PNG, which may not shrink — the keep-if-smaller rule covers that). Strip metadata (EXIF/GPS) —
  it is a compressor, and this is where silent bytes hide.
- **Video** (`AVAssetExportSession`): preset chips map to
  `AVAssetExportPresetHEVC1920x1080` / `HEVCHighestQuality` / `1280x720` etc.; async with progress
  surfaced on the menu-bar item; never block the main thread.
- **PDF** (`PDFKit`): `PDFDocument` re-write with image-optimization write options; if the result
  is not smaller, keep the original (same rule as everything else).

### 3. The module — `Sources/FreeSpeech/Modules/Clop/ClopModule.swift`

- `AppModule` conformance following `AutoclickModule` exactly: lazy runtime, hotkey token (only if
  the user records one; no default hotkey), `setMenuBarItemVisible` building the `NSStatusItem`
  with an `NSMenuDelegate` menu.
- **Watcher**: 0.5s timer polling `changeCount` only while active AND watching (pause state is a
  module-level flag surfaced in the menu and the icon). On new content: classify (image data /
  file URLs by UTType), run the plan gate, encode off the main thread, then write back to the
  pasteboard and remember the resulting changeCount. Log every decision (processed, skipped and
  why, saved how much) via `Log.info` — verbose logging is house style.
- **Undo**: keep the last pre-optimization pasteboard snapshot (and for file replacement, the
  backup path) and restore it from the menu.
- **Menu**: status line (watching/paused + last result), Pause/Resume, Optimize Clipboard Now,
  Optimize Files…, Undo Last Optimization, separator, Clop Settings…
- **Settings pane**: `DSSettingsCard` sections per the Definition of Done list; live changes apply
  to the next optimization (no restart).

### 4. Registration

- Flip `ModuleCatalog.clop` to `.available` (keep summary/symbol).
- Replace the placeholder registration in `AppDelegate` with
  `registry.register(ClopModule(settings: settings, hub: eventHub))`.

## Verification / acceptance

- `swift test $(for l in vendor/lib/*.a; do echo -Xlinker $l; done)` — every existing test plus the
  new `ClopPlanTests` pass.
- `./build.sh --skip-model` — green, signed, installed. (Retry once on a concurrent-edit build error.)
- Self-drive what you can: run the built binary's logic indirectly is not possible for pasteboard UX,
  but you CAN exercise the encoders headlessly — add a temporary scratch harness or test fixture
  (small generated CGImage → encode → assert smaller / correct pixel size) inside the Core-adjacent
  tests where pure, and delete any scratch files afterward.
- Flag for the user (agent cannot verify by hand): copying a large screenshot shrinks it on the
  clipboard and pastes correctly into Preview/Slack; Undo restores the original; video/PDF file
  optimization produces playable/openable output; pause and the menu-bar states behave; toggling the
  module off stops all polling.

## Settled decisions

- Native frameworks only (ImageIO, AVFoundation, PDFKit) — no bundled binaries (no ffmpeg/pngquant),
  no new dependencies, local-only.
- Default OFF (menu bar stays uncluttered until opted in); images-on-copy is the default watch set;
  videos/PDFs default to file-flow only.
- Keep-if-smaller is non-negotiable and applies to every path (clipboard, file, video, PDF).
- File replacement always backs up to `Application Support/FreeSpeech/clop-backups/` first;
  "alongside" naming is `name (clopped).ext`.
- Same module folder/file layout, Settings-key namespacing (`module.clop.*` via the existing
  helpers), DS components, and test idioms as every other module.

## Still open — propose, don't block

- **HEIC vs JPEG default** for the convert policy (HEIC is smaller, JPEG pastes everywhere). Pick
  one, comment the tradeoff, expose the other as the chip alternative.
- **Default image quality** (suggest 0.75) and **default max dimension** (suggest off) — pick,
  comment, move on.
- **Menu-bar drop zone / floating thumbnail** (real Clop has these): out of scope this pass unless
  trivially cheap; leave a commented seam where a drag-target could attach to the status item.
- **Per-app exclusion list** (never touch copies from certain apps, e.g. password managers —
  compare `NSPasteboard` `org.nspasteboard.ConcealedType` marker): implement the concealed-type
  skip (it is one guard and clearly right); a full per-app list can wait — note it in the pane text.
