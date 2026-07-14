# Autoclick (displayed as "Tap")

Fixed-interval synthetic clicks at the cursor or a captured point; also runs recorded click/key
macros.

**Entry point:** `AutoclickModule.swift` — posts the actual `CGEvent`s; scheduling math lives in
Core.

**Core logic:** `Sources/FreeKitCore/Modules/AutoclickPlan.swift` (interval/target/mode) and
`Macro.swift` (recorded step sequence, `MacroStep` — a `Codable` enum so macros serialize straight
to `Settings`/JSON and the executor is a dumb interpreter).

**Gotcha:** id is `"autoclicker"` (predates the "Tap" display-name rename) — don't rename the
catalog `id`, it's the `Settings` key prefix for every user's existing persisted config.
