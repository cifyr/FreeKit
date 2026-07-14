# Stats

Live CPU/memory/network-throughput/Bluetooth-battery readout, modeled after the Stats app —
each stat can show in the dropdown, or promote to its own menu-bar item.

**Entry point:** `StatsModule.swift`.

**Core logic:** `Sources/FreeSpeechCore/Modules/StatsFormatting.swift` — pure formatting (bars,
percent clamping, uptime/minutes/throughput display strings), fully unit-tested since it's the
part most worth getting exactly right without eyeballing a live menu bar.
