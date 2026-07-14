# Stats

Live CPU/memory/network-throughput/device-battery readout, modeled after the Stats app —
each stat can show in the dropdown, or promote to its own menu-bar item.

**Entry point:** `StatsModule.swift`. Device battery merges two sources: an IOKit registry
scan for HID-over-Bluetooth accessories (Magic Mouse/Keyboard/Trackpad, AirPods, and
similar — synchronous, runs on every sample), and `IDeviceBatteryReader.swift` for
iPhone/iPad/Apple Watch battery on anything already trust-paired over USB or WiFi sync
(asynchronous, throttled to its own 30s interval since each lockdownd/companion_proxy round
trip can take seconds — see `StatsSampler.deviceBatteries()`).

**Core logic:** `Sources/FreeKitCore/Modules/StatsFormatting.swift` — pure formatting (bars,
percent clamping, uptime/minutes/throughput display strings, device-battery sorting/icons),
fully unit-tested since it's the part most worth getting exactly right without eyeballing a
live menu bar.

**Third-party dependency:** `IDeviceBatteryReader.swift` links against Homebrew's
[libimobiledevice](https://libimobiledevice.org) (LGPL-2.1-or-later) via the `CIMobileDevice`
system-library target (`Sources/CIMobileDevice/`) — `lockdownd`'s `com.apple.mobile.battery`
domain for iPhone/iPad, `companion_proxy` for a Watch paired to that iPhone. `build.sh` vendors
the headers and dylibs at build time (dynamically linked, not statically, so the library stays
independently replaceable — the standard LGPL compliance path for a closed-source app); the
license text ships at `Resources/libimobiledevice-COPYING.txt` and in every built app at
`Contents/Resources/libimobiledevice-COPYING.txt`. WiFi-sync discovery needs the
`NSLocalNetworkUsageDescription` + `NSBonjourServices` (`_apple-mobdev2._tcp.`) entries in
`Resources/Info.plist` to clear macOS's Local Network permission prompt.
