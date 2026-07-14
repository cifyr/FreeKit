# Devices

Menu bar battery readout for paired Bluetooth accessories — AirPods, Magic Mouse/Keyboard/
Trackpad, and anything else that publishes `BatteryPercent` over HID-over-Bluetooth. Click the
status item for a popup, click anywhere else to dismiss it. No hotkey, no settings pane.

There is no public API for other iCloud devices' battery (iPhone/iPad/Watch continuity), so this
covers Bluetooth-paired accessories only.

**Entry point:** `DevicesModule.swift` (status item, IOKit scan). Popup panel and SwiftUI view:
`DevicesPanel.swift`.

**Core logic:** `Sources/FreeSpeechCore/Modules/DevicesPlan.swift` — pure formatting, sorting, and
low-battery/icon lookups, unit-tested in `Tests/FreeSpeechCoreTests/DevicesPlanTests.swift`.
