# Amphetamine

Keep the Mac awake on demand: timer tiers from the menu bar icon's click menu, or a right-click
"Stay Awake" toggle that holds until the next right-click.

**Entry point:** `AmphetamineModule.swift`. Sessions hold `IOPMAssertionCreateWithName`-based
assertions (`PreventUserIdleSystemSleep`, plus `PreventUserIdleDisplaySleep` when "keep the
display awake" is on). The assertions belong to the module object, not a window, so closing every
FreeKit window leaves the session running; quitting FreeKit releases it.

**Core logic:** `Sources/FreeKitCore/Modules/AmphetaminePlan.swift` (`AmphetaminePlan` —
duration presets, countdown text, vector policy, battery-floor rules), tested in
`Tests/FreeKitCoreTests/AmphetaminePlanTests.swift`.

**Hard limitation (documented in the UI, not papered over):** closing the lid with no external
display attached forces sleep regardless of any user-space assertion. The only lever is the
root-only `SleepDisabled` system setting (`pmset disablesleep`), which v1 deliberately does not
request; see the comment atop `AmphetamineModule.swift` if a sudo-based opt-in ever becomes worth it.
