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
4. On first launch, a **setup guide** walks you through the permissions the suite can use —
   **Accessibility**, **Microphone**, **Screen Recording**, and **Camera**, each explaining what
   it's for — then helps you turn on the tools you want, one at a time, and set their hotkeys.
   Everything starts off; you enable only what you use. The guide updates automatically as you
   grant permissions in System Settings.

## Using it

- Open **FreeKit** and turn on the tools you want from **Control Center** (the setup guide does this too).
- **Speech**: once enabled, hold your dictation hotkey (**Right Option** by default) and speak, then
  release — your words are inserted wherever the cursor is. A separate hotkey transcribes system audio
  (e.g. the other side of a call).
- Each tool keeps its own **Settings** — change hotkeys, models, vocabulary, and options there anytime.

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
