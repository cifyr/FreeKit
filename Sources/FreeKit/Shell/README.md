# Shell

App-level infrastructure that isn't part of any module: `AppDelegate` (composition root — this is
where new modules get `registry.register(...)`'d), `DesignSystem` (the whole visual language —
colors/type/motion under the `DS`/`ds*` prefix, shared by every module's UI), `AppearanceManager`,
`StatusBarController`, `Permissions`/`PermissionCoach` (authorization checks + guided-grant UI for
mic/accessibility/camera/screen-recording, used across modules), `UpdateManager`.

`Sources/FreeKit/main.swift` (one level up) is the actual entry point — left out of this folder
so it stays where SPM's top-level-executable-code convention expects to find it, though its
location doesn't functionally matter to the build.

See `CLAUDE.md` for how this differs from `Modules/Shared/` (module-*system* infrastructure).
