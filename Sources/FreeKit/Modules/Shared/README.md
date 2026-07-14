# Shared

Not a module — the module *system* itself, plus cross-module coordination that doesn't belong to
any single tool. See `CLAUDE.md` for the full breakdown of what lives here and why. Short version:

- `Module.swift` — the `AppModule` protocol and `ModuleRegistry`.
- `ControlCenterWindow.swift`, `ModuleSettingsWindow.swift`, `ModuleGuide.swift` — the shared
  settings-hosting UI every module's popup renders inside.
- `EventTapHub.swift`, `ShortcutCapture.swift`, `HotkeyRecorderButton.swift` — the one global
  hotkey event tap every module shares, and the reusable recorder control for configuring one.
- `OverlayLayoutCoordinator.swift`, `PanelFade.swift` — keep floating panels from stacking on each
  other, and shared open/close animation.
- `SuiteDropZoneCoordinator.swift`, `SuiteServiceBridge.swift` — the drag-and-drop and Finder
  Services entry points shared by Clop and Convert.

If you're adding something here, ask first whether it's really needed by more than one module —
if not, it probably belongs in that module's own folder instead.
