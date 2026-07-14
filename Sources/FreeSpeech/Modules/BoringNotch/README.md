# BoringNotch

Now-playing (Spotify/Apple Music via `SystemNowPlaying.swift`) and the next calendar event
(EventKit), docked beside the physical notch.

**Entry point:** `BoringNotchModule.swift`. No extracted `FreeSpeechCore` logic yet — if you find
yourself writing non-trivial pure logic here (layout math, state transitions), consider giving it
a `BoringNotchPlan.swift` in Core rather than growing the app-side file indefinitely.

**Gotcha:** its panel level is `.statusBar + 1` (higher than the other floating panels) so it can
sit above the real notch/menu-bar-item area; if panels start fighting for stacking order, check
`Modules/Shared/OverlayLayoutCoordinator.swift` before just bumping levels further.
