# HyperKey

Remap the Caps Lock key to a hyper key, plain Command, or tap-for-Escape.

**Entry point:** `HyperKeyModule.swift`. Two layers: `hidutil` remaps physical Caps Lock to F18 at
the HID level (a session-level event tap can't see Caps Lock press/release — the toggle happens
below it, and this also keeps the Caps Lock LED off), then the shared event tap
(`Modules/Shared/EventTapHub.swift`) turns F18 into whatever's configured.

**Core logic:** `Sources/FreeKitCore/Modules/HyperKey.swift` (`HyperKeyMapper` — the decision
logic for what an F18 down/up becomes; named for the concept, not the module, since it's the
event-remap logic rather than a "plan").

**Naming note:** this module used to be called CapsLock; the persisted catalog id is still
`"capslock"` on purpose so pre-rename installs keep their saved enabled state. Only display
strings and source/type names changed.

**Gotcha:** if `hidutil`'s remap isn't reapplied (e.g. after sleep/wake in some configurations),
Caps Lock reverts to stock behavior — check the hidutil-reapply path here before assuming a
HyperKey bug is in the event-tap logic.
