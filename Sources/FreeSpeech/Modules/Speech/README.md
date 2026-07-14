# Speech

The original app, before there was a "suite": hold a hotkey, speak, on-device whisper.cpp
transcribes it, optional post-processing cleans/rewrites it, and it lands at the caret.

**Entry point:** `SpeechModule.swift`. Everything else here is the pipeline it drives — audio
capture (`AudioRecorder`, `AudioDevices`, `PCMSampleAccumulator`, `SystemAudioRecorder` for the
"transcribe the other side of a call" mode), the whisper.cpp wrapper (`WhisperEngine`), output
(`PostProcessor`, `TextInserter`), UI (`HUDController`, `SettingsWindow`, `HistoryWindow`,
`OnboardingWindow`), `AXFieldReader`/`EditWatcher` (reads the focused field for
continue-don't-duplicate insertion and the edit-learning loop), and `ModelDownloader`.

**Core logic:** `Sources/FreeSpeechCore/Modules/Speech/` — the state machine, post-processing
modes, edit-learning, speaker splitting, spoken-command parsing, transcript cleanup, model
catalog, and dictation history store. This is the biggest module by far and predates the module
system (it's why its Core logic is a whole subfolder instead of one flat `<Name>Plan.swift`).

**Gotcha:** the model must be resident before transcription — `ModelDownloader`/model catalog
logic assumes `AppPaths.installedModels()` has at least one entry; `build.sh` (without
`--skip-model`) fetches the default one.
