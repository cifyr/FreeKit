# Devices

Menu bar battery readout for paired Bluetooth accessories — AirPods, Magic Mouse/Keyboard/
Trackpad, and anything else that publishes `BatteryPercent` over HID-over-Bluetooth — plus
iPhone, iPad, and Apple Watch battery for devices already trust-paired to this Mac over USB or
WiFi sync. Click the status item for a popup, click anywhere else to dismiss it. No hotkey, no
settings pane.

**Entry point:** `DevicesModule.swift` (status item, IOKit Bluetooth scan). Popup panel and
SwiftUI view: `DevicesPanel.swift`. iPhone/iPad/Watch battery: `IDeviceBatteryReader.swift`, via
`CIMobileDevice` (see below) — silently returns nothing for a device that isn't trust-paired,
same as the Bluetooth scan silently skips accessories that aren't connected.

**Core logic:** `Sources/FreeSpeechCore/Modules/DevicesPlan.swift` — pure formatting, sorting, and
low-battery/icon lookups, unit-tested in `Tests/FreeSpeechCoreTests/DevicesPlanTests.swift`.

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
