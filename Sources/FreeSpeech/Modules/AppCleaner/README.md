# AppCleaner

Uninstall apps together with their leftover support files (prefs, caches, logs, saved state).

**Entry point:** `AppCleanerModule.swift`. No extracted `FreeSpeechCore` logic yet — the file-scan
and removal logic lives here since it's tightly coupled to `FileManager`/`Darwin` APIs that
wouldn't gain much from a pure-Foundation split.

**Gotcha:** this is a destructive-by-design tool. Any change to what counts as a "leftover file"
or the removal path deserves extra scrutiny and manual testing — a false positive means deleting
something that wasn't actually the target app's.
