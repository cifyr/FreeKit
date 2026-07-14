# Convert

Local drag-and-drop file conversion (image/audio/video/document), the CloudConvert/FreeConvert
niche without the upload. Two tabs: **Tool** (persisted defaults, used by Finder-menu and
background drop-zone conversions) and **App** (`ConvertAppTab.swift` — interactive, pick a file,
choose output format/quality, Save-alongside or Replace-original).

**Entry point:** `ConvertModule.swift`. Conversion logic itself is `ConvertEngine.swift`
(pure-ish, but stays in the app target because it uses ImageIO/AVFoundation/PDFKit directly).
`ConvertToast.swift` is the transient result notification.

**Core logic:** `Sources/FreeKitCore/Modules/ConvertPlan.swift` (format/quality plan types,
what's convertible to what).

**Gotcha:** "Replace Original" always backs up and removes the source file the same way — don't
special-case a new conversion path's delete behavior; follow the existing pattern in
`ConvertEngine`/`ConvertModule` so a bug in one path doesn't diverge from the others.
