# Shelf

Wiggle a drag to park file(s) on a floating shelf, then drop them wherever you actually want them
— for when you don't have both windows visible at once.

**Entry point:** `ShelfModule.swift` (gesture detection + registration). `ShelfPanel.swift` is the
floating panel + its SwiftUI content.

**Core logic:** `Sources/FreeKitCore/Modules/ShelfPlan.swift`.

**Gotcha:** the panel's `isMovableByWindowBackground` is deliberately `false` — the header strip
is the only drag handle, because background dragging would consume the mouse-down a row's
`.onDrag` needs to pull a file back off the shelf.
