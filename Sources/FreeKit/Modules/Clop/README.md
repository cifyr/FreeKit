# Clop

Automatic image/video/PDF compression on copy — inspired by the macOS app of the same name.

**Entry point:** `ClopModule.swift`. `ClopOptimizer.swift` does the actual compression work;
`ClopToast.swift` is the transient result notification (shares the drop-zone entry point in
`Modules/Shared/SuiteDropZoneCoordinator.swift` with Convert).

**Core logic:** `Sources/FreeKitCore/Modules/ClopPlan.swift`.

**Gotcha:** no persistent menu-bar toggle — `ownsMenuBarItem` is `false` in its `ModuleInfo`
(see `CLAUDE.md`'s module table); it self-manages visibility instead. Don't reintroduce a manual
toggle without checking why it was removed (see git history / commit "drop the menu-bar toggle").
