# /goal

Give the entire FreeSpeech / FreeKit suite a cohesive **motion and micro-polish pass** so every
surface — the dictation HUD, Settings, History, Onboarding, the Control Center, and every module's
menu-bar UI, panels, toasts, and settings panes — animates and responds like a shipped, intentional
Mac product instead of a static prototype. The motion must feel like one hand designed it: calm,
native, decelerate-curved, reserved. Do this **autonomously with subagents**, one surface per agent,
fanning out from a single shared motion vocabulary you establish first. Work on branch
`design/motion`; change **no behavior** and keep every existing test green; build with
`./build.sh --skip-model`; commit per surface with explicit file lists; do NOT merge, do NOT push —
the user runs it, judges the feel, and merges. Motivation: this is a reliability-first tool the user
lives in all day. When a motion choice is unspecified, choose the quieter, shorter, more native
option over the flashier one. "Impressive" here means *effortless and coherent*, never *bouncy*.

## Definition of done

- [ ] A shared **motion grammar** lives in `Sources/FreeSpeech/DesignSystem.swift` (extending the
      existing `DS` duration tokens and the "one decelerate curve" philosophy): a small set of named
      animations and reusable view modifiers (press, hover, appear, list-stagger, value-change,
      live-pulse, crossfade) that every surface consumes. No view inlines its own curve or duration.
- [ ] **Reduce Motion is respected everywhere.** When `accessibilityReduceMotion` (SwiftUI env) /
      `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (AppKit) is on, motion collapses to
      instant state changes (opacity-only crossfades at most) — never a jarring cut mid-animation.
      This gating lives in the motion grammar so every surface inherits it for free.
- [ ] Every user-facing surface visibly improved with **subtle** motion + touch-ups: HUD, Settings,
      History, Onboarding, ControlCenterWindow, ModuleSettingsWindow, and each module's menu-bar
      menu / panel / toast / settings pane (Autoclick, AppCleaner, BoringNotch, CapsLock, Clop,
      Notebook, Shelf, Speech, Stats).
- [ ] **No behavior changes** anywhere: pipeline, hotkeys, settings persistence, module enable/disable,
      window functions, pasteboard logic — all identical. `FreeSpeechCore` is untouched. This is a
      view-layer motion pass only.
- [ ] **HUD contract intact:** still a single-line, 280x44, non-activating (`.nonactivatingPanel`)
      panel that appears the instant the hotkey fires (no expensive setup on show), never steals
      focus, never grows to a second row, and its waveform never spins the CPU when idle.
- [ ] Every color/radius/type value still comes from `DS` tokens; no new accent hues; SF / SF Mono
      only; dark-only; no emojis; comments explain *why* only.
- [ ] `swift test $(for l in vendor/lib/*.a; do echo -Xlinker $l; done)` and `./build.sh --skip-model`
      are green (all existing tests pass; add tests only if you introduce pure helper logic worth
      testing — motion itself is human-judged, not unit-tested).
- [ ] Committed on `design/motion` in per-surface commits with explicit file lists; NOT merged; NOT
      pushed. A final commit message (or a `prompts/motion-report.md`) lists, per surface, exactly
      what motion was added so the user knows what to look at.

## Read first

1. `/Users/caden/.claude/CLAUDE.md` — global working rules (branching, explicit-file commits,
   archive-not-rm, no emojis, comments explain why, no merge/push without asking). Load-bearing.
2. `Sources/FreeSpeech/DesignSystem.swift` — the `DS` token set. Note it **already has** the motion
   seed: `durInstant 0.12`, `durBase 0.20`, `durSlow 0.32`, `hudCrossfade 0.18`, and the stated
   philosophy "one decelerate curve for all interface motion keeps the app calm; only the pulse
   breathes symmetrically." The existing `GhostButtonStyle`, `DSChip`, `DSTabButton`, `DSCheckbox`
   already animate hover/press at `durInstant` — match and centralize that idiom; do not replace it.
3. `DESIGN_BRIEF.md` and `DESIGN_BRIEF_CLAUDE_DESIGN.md` — the "Greenlight red" design language,
   surface-by-surface descriptions, and the calm/native/quiet taste bar. Authoritative on look.
4. `prompts/clop-module-prompt.md` — the house prompt/format and the module pattern context.
5. Before touching any surface, read that surface's file(s) in full (see Task spec for the file map).

## Context: what exists

- SwiftPM app, macOS 26 target. `FreeSpeechCore` is pure Foundation (tests, no AppKit). `FreeSpeech`
  is the app target (AppKit + SwiftUI). Tests link whisper static libs (the `-Xlinker` invocation
  above). `./build.sh --skip-model` runs tests, builds, signs "FreeSpeech Dev", installs to
  `/Applications/FreeSpeech.app`.
- Design language: dark-only "Greenlight red" — ink surface scale `ink0`–`ink3`, hairline `line`,
  `paper` text, `muted`/`faint` secondary, accent red `#FF453A` reserved for **live/active voice**
  (waveform, selection, live tags), never decoration. Continuous-corner radii. Uppercase SF Mono
  micro-labels with 1.2 tracking as the "label voice."
- Surfaces are largely one-file-each and independent, which is what makes clean subagent fan-out
  possible. The only shared view file is `DesignSystem.swift` — it is touched **only** in Phase 1.
- Two motion-bearing helpers already exist and should be folded into / aligned with the grammar:
  `Sources/FreeSpeech/Modules/PanelFade.swift` and
  `Sources/FreeSpeech/Modules/OverlayLayoutCoordinator.swift`.

## Orchestration — how to run this with subagents

You (the top-level session) are the **conductor**, not the implementer. Run three phases:

**Phase 1 — Establish the grammar (you do this alone, first, and commit it).**
Read `DesignSystem.swift`, then extend it with the motion vocabulary (see next section). Build, run
tests, and commit `DesignSystem.swift` (plus `PanelFade.swift`/`OverlayLayoutCoordinator.swift` if
you fold them in) on `design/motion` with an explicit file list. Nothing fans out until this is
committed — it is the contract every subagent depends on.

**Phase 2 — Fan out one subagent per surface, in isolation.**
Spawn a subagent for each surface in the Task spec, each in its **own git worktree** off the Phase 1
commit (`isolation: "worktree"`), so parallel edits and builds never collide. Give each agent: the
`/goal`, the Hard constraints, the motion-grammar reference (it is already committed, so the agent
reads it), and only its surface's file map + motion opportunities. Each agent (a) reads its files in
full, (b) adds motion strictly from the grammar, (c) builds + runs tests in its worktree, (d) commits
its own file set with an explicit list, (e) returns a one-paragraph report of what it animated. Group
small related files into one agent (e.g. all three Clop files together) so each agent owns a coherent,
disjoint file set. No two agents touch the same file.

**Phase 3 — Integrate and review (you).**
Bring each worktree's commit back onto `design/motion` (fast-forward/merge; there should be zero
conflicts because file sets are disjoint and `DesignSystem.swift` is frozen after Phase 1). Then run
one **consistency-reviewer subagent** over the full diff whose only job is to flag: any inlined
curve/duration not from the grammar, any off-token color/radius, any behavior change, any missing
Reduce-Motion path, any motion louder than the calm bar (bounce/overshoot/spin), and any HUD-contract
violation. Fix what it finds. Final full build + test. Write the per-surface motion report.

If a subagent's worktree build fails on a concurrent-edit or missing-vendor error, retry once; do not
revert files you did not intend to touch.

## The motion grammar (Phase 1 — build this before anything fans out)

Add to `DesignSystem.swift` a cohesive, reduce-motion-aware motion layer built on the existing tokens.
Design it so a view says *what* is happening (appearing, pressed, value changed) and the grammar owns
*how* it moves. Suggested shape (adapt names to fit the codebase idiom):

- **Named animations** on the one decelerate curve, gated by reduce-motion in a single place:
  `DS.motion.instant` (≈`durInstant`), `.base` (≈`durBase`), `.slow` (≈`durSlow`), `.crossfade`
  (≈`hudCrossfade`). Each returns `nil`/near-zero when Reduce Motion is on so `withAnimation` becomes
  an instant state change. Expose a SwiftUI helper that reads `@Environment(\.accessibilityReduceMotion)`
  and an AppKit helper reading `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- **Reusable modifiers** (SwiftUI) covering the recurring gestures so no surface reinvents them:
  - press feedback (scale ≈0.97 + `durInstant`), unified with the existing button styles' press idiom
  - hover lift (the existing `controlHover`/`ink3` treatment, centralized)
  - appear/disappear transition (opacity + a few-pt offset/scale in, `durBase`) for cards/rows/panels
  - list stagger (`appear`, delayed by index, small cap so long lists don't cascade forever)
  - value-change transition for numbers/labels (Stats counters, saved-bytes, timers) — crossfade or
    a short count roll, never a slot-machine spin
  - live-pulse (the symmetric breathing dot already described for the HUD — the one ease-in-out
    exception), reused for any "working/active" indicator across modules
  - crossfade-content for state swaps (HUD waveform↔text, hover-reveal buttons)
- **AppKit equivalents** where views are `NSView`/`NSPanel` (HUD, several module panels/toasts): a
  small `NSAnimationContext`/`CABasicAnimation` helper pair mirroring the same durations + curve +
  reduce-motion gate, so AppKit and SwiftUI surfaces feel identical.

Constraints on the grammar itself: one decelerate timing curve for all directional motion; the pulse
is the only symmetric ease-in-out; no springs with visible overshoot; nothing longer than `durSlow`
(≈0.32s) except a deliberately slow ambient idle (waveform/pulse). Comment the *why* on each token.

## Hard constraints / do not

- **Do NOT change behavior, wiring, logic, or copy.** No renamed settings keys, no changed callbacks,
  no new features, no new dependencies, no new SPM targets. If a motion needs a state flag, keep it
  view-local; never alter persisted state or module logic.
- **Do NOT touch `FreeSpeechCore`.** All work is in the `FreeSpeech` target's view files.
- **Do NOT leave the design system:** dark-only, red `#FF453A` family only (no new accent hues),
  SF/SF Mono only, all values from `DS`. Extend `DS` (motion) only in Phase 1.
- **Do NOT break the HUD contract:** single line, `.nonactivatingPanel`, never steals focus, appears
  instantly on hotkey (no work deferred into the show path that adds latency), waveform must idle
  cheaply (no busy CPU when not speaking), never a second row.
- **"Subtle" is a hard limit, not a vibe:** durations ≤ ~0.32s (ambient idle excepted); animate
  opacity/scale/offset, not layout thrash or reflow; no motion on every keystroke; no more than one
  thing drawing attention at once on a surface; no bounce/rubber-band/confetti. If in doubt, make it
  shorter and quieter.
- **Performance:** no animation may run when its view is offscreen/closed; menu-bar and HUD idle
  animations must not peg a core; invalidate timers/`CADisplayLink`s on hide. Never animate during
  the HUD's critical appear path in a way that delays first paint.
- **No emojis anywhere.** Comments explain *why* only. Archive whole-file removals to
  `.archive/<UTC-timestamp>/…` — do not `rm`.
- Per-surface commit at the end of each agent's work (build + tests green) with an explicit file
  list. Do NOT merge, do NOT push.

## Task spec — the fan-out units (one subagent each, disjoint files)

For each unit: read the file(s) fully, find the natural motion moments listed, apply them from the
grammar, keep behavior identical, build + test, commit. The lists below are opportunities, not a
checklist to exhaust — pick the ones that raise perceived quality and skip anything that would fight
the calm bar.

1. **HUD** — `HUDController.swift` (AppKit `NSPanel` + `WaveformLineView`). The most-seen pixels.
   Smooth the waveform envelope (organic decay, peak rounding, symmetric idle ripple), crossfade
   between waveform and status text (`hudCrossfade`), refine the appear/dismiss (fade + small slide,
   no bounce), the `POLISHING`/`TRANSCRIBING` pulsing dot, and the `SYSTEM AUDIO` tag's entrance.
   Guard first-paint latency and idle CPU.
2. **Settings** — `SettingsWindow.swift`. Tab-underline slide between tabs (`DSTabButton`), card/row
   appear + light stagger on tab switch, unified hover/press on every interactive row, custom
   dropdown open/close (if a stock `Menu` is restyled), replacement-dictionary and per-app-rule
   row insert/remove transitions, scroll-linked header hairline.
3. **History** — `HistoryWindow.swift`. Row appear + stagger, hover-reveal Copy/Insert (crossfade in,
   not always-visible), a brief copy-confirmation flash, search-filter transition, empty-state fade.
4. **Onboarding** — `OnboardingWindow.swift`. Step-to-step transition (slide/crossfade), step counter
   / progress fill animation, permission `GRANTED` tag pop, and the practice-dictation box as the
   hero moment (it shows the HUD working — make it feel alive without distracting).
5. **Control Center** — `ControlCenterWindow.swift`. Card-grid appear/stagger, ON and menu-bar toggle
   state transitions, gear/hover feedback, live status pulses for active modules.
6. **Shared module chrome** — `Modules/ModuleSettingsWindow.swift`, `Modules/HotkeyRecorderButton.swift`,
   `Modules/PanelFade.swift`, `Modules/OverlayLayoutCoordinator.swift` (if not already folded into
   Phase 1). Settings-card/section appear, `DSToggleRow`/`DSNumberField` feedback, the hotkey
   recorder's recording-state indicator, and centralized panel fade/layout so all module panels share
   one entrance.
7. **Clop** — `Modules/Clop/ClopModule.swift`, `ClopToast.swift`, `ClopDropZone.swift`. Toast
   slide-in/out + saved-bytes value transition, drop-zone hover/drag-target highlight, working
   spinner/progress, menu-bar icon state transitions (watching/paused/working).
8. **Stats** — `Modules/Stats/StatsModule.swift`. Count-up / value-change on numbers, bar/chart grow
   on appear, refresh transitions — the surface most improved by tasteful value motion; keep it calm.
9. **Notebook** — `Modules/Notebook/NotebookModule.swift`. Panel/entry appear, list insert/remove,
   selection and hover feedback.
10. **BoringNotch** — `Modules/BoringNotch/BoringNotchModule.swift`. Expand/collapse of the notch
    surface (its signature interaction — make it feel physical but not bouncy), content crossfade.
11. **Shelf** — `Modules/Shelf/ShelfPanel.swift`, `ShelfModule.swift`. Panel entrance (the
    shake-to-park moment is a delight beat — reward it), parked-file item appear/remove, hover.
12. **Autoclick** — `Modules/Autoclick/AutoclickModule.swift`. Active-state pulse on the menu-bar
    icon, settings-pane feedback, any running-indicator.
13. **AppCleaner** — `Modules/AppCleaner/AppCleanerModule.swift`. Scan progress, result list appear,
    selection/hover, action feedback.
14. **CapsLock + Speech + Permission coach** — `Modules/CapsLock/CapsLockModule.swift`,
    `Modules/Speech/SpeechModule.swift`, `PermissionCoach.swift`. Indicator/state transitions,
    permission-row status changes, coach-panel entrance.

## Verification / acceptance

- Per agent (in its worktree) and finally on `design/motion`:
  `swift test $(for l in vendor/lib/*.a; do echo -Xlinker $l; done)` — all existing tests pass;
  `./build.sh --skip-model` — green, signed, installed.
- **Self-checkable:** grep the final diff for inlined `.easeIn`/`.easeOut`/`.spring`/`Animation(`/
  hard-coded durations outside `DesignSystem.swift` — there should be essentially none (surfaces call
  the grammar). Confirm no `FreeSpeechCore` file changed and no settings key/callback names changed.
- **Reduce Motion:** with `System Settings > Accessibility > Display > Reduce Motion` on, every
  surface still functions and transitions read as instant/opacity-only — no half-played animations.
- **Human-only (flag explicitly, agent cannot judge):** the actual feel and timing during real
  dictation and real module use; whether any motion distracts; the HUD's calm during thinking/speaking.
  State per surface what was animated so the user knows exactly what to look at.

## Settled decisions

- Motion-led visual polish; Greenlight-red; dark-only; calm/native/quiet is the taste bar.
- One shared motion grammar in `DesignSystem.swift`, established and committed before any fan-out;
  every surface consumes it; nothing inlines curves.
- Subagent-per-surface in isolated worktrees; disjoint file ownership; conductor integrates + runs a
  consistency review; per-surface commits on `design/motion`; no merge, no push.
- Reduce Motion and idle/offscreen performance are non-negotiable, not optional polish.
- Native AppKit (HUD, some panels) + SwiftUI (windows/panes) stay as they are — no rewrites.

## Still open — propose, don't block

- Exact curve shape, per-gesture durations within the token bounds, stagger delay/cap, and the
  count-up style for Stats: pick tasteful values, comment the rationale once in `DesignSystem.swift`,
  and keep going. Do not stop to ask.
- Scope of non-motion touch-ups (spacing/hierarchy nudges): allowed **only** where they directly
  support the motion (e.g. a hover target that needs padding to feel right). A broad static redesign
  is out of scope — `DESIGN_BRIEF.md` already covers that separately. When unsure, do less.
- If a stock control genuinely cannot animate acceptably, a custom Greenlight equivalent with
  identical behavior is acceptable — note the tradeoff in a one-line comment.
