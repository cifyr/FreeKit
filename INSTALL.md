# Installing FreeKit

FreeKit is a local-first menu bar utility suite for macOS. Everything runs on your Mac — nothing is sent to the cloud.

## Requirements

- **Apple Silicon Mac** (M1 or newer)
- **macOS 26 or newer**

If your Mac is Intel-based or on an older macOS, it will not run.

## Install

1. **Unzip** the file you were sent (double-click it in Finder).
2. **Right-click `install.command` and choose Open** — do not double-click it.
   - The first time, macOS says it's from an unidentified developer. Click **Open** to continue.
   - This is expected: the app isn't signed through the App Store. It's safe — it runs entirely on your machine.
3. The installer copies the app to your Applications folder, installs the speech model
   (or, for the small download, fetches it on first launch — needs internet once), and opens the app.
4. On first launch, a **setup guide** walks you through granting two permissions:
   - **Microphone** — to hear your voice.
   - **Accessibility** — to type the transcribed text into whatever app you're using.
   Both are required. Follow the steps; the guide updates automatically once you grant them in System Settings.

## Using it

- **Hold Right Option** and speak, then release — your words are inserted wherever your cursor is.
- FreeKit lives in the **Dock**, with optional per-tool menu bar controls for settings, models, and the
  separate hotkey that transcribes system audio (e.g. the other side of a call).
- Change the hotkey, model, and vocabulary anytime in **Settings**.

## Troubleshooting

- **`install.command` won't open:** open the Terminal app, drag `install.command` into the window,
  and press Return.
- **"App is damaged / can't be opened":** the quarantine flag wasn't cleared. Open Terminal and run:
  `xattr -dr com.apple.quarantine /Applications/FreeKit.app`
- **Dictation inserts nothing:** make sure **Accessibility** is enabled for FreeKit in
  System Settings → Privacy & Security → Accessibility.
- **Transcription is inaccurate:** check your input device and model in Settings. The recommended
  model ("Turbo (compact)") gives the best accuracy.
- **First launch says it's downloading:** the small package fetches the ~550 MB model once. Leave it
  connected to the internet until the menu bar stops showing "Downloading model".
