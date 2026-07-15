<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/banner-dark.png">
  <source media="(prefers-color-scheme: light)" srcset=".github/assets/banner-light.png">
  <img alt="FreeKit — local macOS utility suite" src=".github/assets/banner-dark.png" width="100%">
</picture>

<br><br>

![Platform](https://img.shields.io/badge/macOS-26+-FF453A?style=flat-square)
![Chip](https://img.shields.io/badge/Apple_Silicon-only-FF453A?style=flat-square)
![Privacy](https://img.shields.io/badge/100%25-on--device-1D1D24?style=flat-square)
![Engine](https://img.shields.io/badge/whisper.cpp-Metal-8E8E99?style=flat-square)

**A local-first menu bar utility suite for macOS — dictation, file conversion, compression, and more, all on-device.**

</div>

---

FreeKit is a native Swift menu-bar suite. It started as a single-purpose dictation app — hold a
key, speak, your words appear wherever the cursor is — and grew into a shelf of independent tools
that share one app, one design system, and one settings surface. No cloud, no account, no
telemetry in any of them: the only network access anywhere in the suite is downloading the speech
model once.

## Speech: the original tool

- **Talk anywhere** — hold your hotkey in any app (Notes, a browser, Slack, your terminal) and the text lands at the cursor.
- **Nothing leaves your Mac** — Whisper runs on-device with Metal acceleration; fully offline after setup.
- **Continue, don't repeat** — reads the field first and picks up where you left off instead of duplicating what you already typed.
- **Catch both sides of a call** — a separate hotkey transcribes system audio, the other person on a Zoom or Meet call.
- **Cleans up as you go** — deterministic tidy-up by default; optional on-device grammar, structure, and tone rewrites.
- **Learns your words** — watches how you edit inserted text and quietly fixes recurring mis-hears.
- **Single-line HUD** — an unobtrusive floating waveform that never steals focus from what you're typing into.

## The rest of the suite

Every module below is independent — enable only what you use, from one Control Center window.

| Module | What it does |
|---|---|
| **Notebook** | Floating scratch notes on a global hotkey, searchable, saved to disk. |
| **Convert** | Drag-and-drop file conversion (image/audio/video/doc), entirely on-device. |
| **Clop** | Automatic image/video/PDF compression the moment you copy one. |
| **Shelf** | Shake a drag to park a file on a floating shelf; drop it in anywhere later. |
| **Boring Notch** | Now-playing controls and your next calendar event, docked beside the notch. |
| **AppCleaner** | Uninstall apps together with their leftover support files. |
| **Tap** | Fixed-interval autoclicker at the cursor or a set point; supports recorded macros. |
| **Stats** | Live CPU, memory, network, and Bluetooth-accessory battery in the menu bar. |
| **HyperKey** | Remap Caps Lock to a hyper key, Command, or tap-for-Escape. |
| **Devices** | Battery level for paired iPhone/iPad/Watch and Bluetooth accessories. |
| **Amphetamine** | Keep the Mac awake on a timer, including with the lid closed. |

Coming soon: **Ice** (menu bar icon manager), **Cotypist** (on-device inline text prediction),
**LinearMouse** (per-device pointer acceleration and scroll).

## Requirements

- **Apple Silicon** Mac (M1 or newer)
- **macOS 26** or newer

## Download & install

### Homebrew (recommended)

```bash
brew tap cifyr/freekit
brew install --cask --no-quarantine freekit
```

`--no-quarantine` is needed because the app is self-signed rather than notarized;
Gatekeeper would otherwise block first launch. Upgrade with
`brew upgrade --cask freekit`, remove everything with
`brew uninstall --zap --cask freekit`. Setting up the tap (and the notarization
path that drops the flag) is documented in **[HOMEBREW.md](HOMEBREW.md)**.

### Direct download

Grab the [latest release](https://github.com/cifyr/FreeKit/releases/latest):

- **FreeKit-share.zip** — model included, works offline immediately.
- **FreeKit-share-lite.zip** — a few MB; downloads the model once on first launch.

Then (see **[INSTALL.md](INSTALL.md)** for detail):

1. Unzip the file.
2. **Right-click** `install.command` → **Open** (approve the one-time unidentified-developer prompt).
3. Grant the permissions the setup guide asks for, then turn on the tools you want.

The app isn't notarized, so the right-click-Open step (or Homebrew's `--no-quarantine`)
is required — a plain double-click is blocked by Gatekeeper. Everything runs on-device.

## Build from source

Requires Xcode command-line tools and `cmake` (`brew install cmake`).

```bash
git clone <this-repo> FreeKit && cd FreeKit
./build.sh                 # vendors whisper.cpp, runs tests, builds dist/FreeKit.app, fetches the model
open dist/FreeKit.app      # grant Microphone + Accessibility on first run
```

To produce a shareable package:

```bash
./package.sh --app-only    # ~4 MB zip; the app downloads its model on first launch
./package.sh               # ~510 MB zip; bundles the model for offline install
```

## Speech's model

Benchmarked on Apple Silicon (see [`bench/RESULTS.md`](bench/RESULTS.md)). The default,
**`large-v3-turbo-q5_0`**, won the matrix — best accuracy while staying fast:

| Model | Accuracy | Speed | Size |
|---|---|---|---|
| **Turbo (compact)** — default | best | fast | 561 MB |
| Large Turbo | high | fast | 1.6 GB |
| Base | good | fastest | 145 MB |
| Tiny | rough | fastest | 74 MB |

Switch models anytime in **Settings**. Each is described by accuracy and speed, not filename.

## How it's built

Native Swift. `FreeKitCore` holds each module's pure, unit-tested logic (state machines, format
plans, catalog data); the `FreeKit` app target wires it to AppKit, CoreAudio, ScreenCaptureKit, and
a vendored [whisper.cpp](https://github.com/ggml-org/whisper.cpp) for Speech specifically. On-device
rewrites use Apple's FoundationModels.

---

<div align="center">
<sub>Runs entirely on your Mac · Apple Silicon, macOS 26+</sub>
</div>
