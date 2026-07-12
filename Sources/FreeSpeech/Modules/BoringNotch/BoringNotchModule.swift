import AppKit
import Combine
import EventKit
import IOKit.ps
import SwiftUI
import FreeSpeechCore

enum BoringNotchMediaSource: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    var id: String { rawValue }
}

final class BoringNotchPreferences: ObservableObject {
    static let shared = BoringNotchPreferences()
    private enum Key {
        static let collapsedWidth = "notch.collapsedWidth"
        static let expandedWidth = "notch.expandedWidth"
        static let expandedHeight = "notch.expandedHeight"
        static let expandOnHover = "notch.expandOnHover"
        static let autoCollapse = "notch.autoCollapse"
        static let collapseDelay = "notch.collapseDelay"
        static let cornerRadius = "notch.cornerRadius"
        static let showAccent = "notch.showAccent"
        static let showMedia = "notch.showMedia"
        static let mediaSource = "notch.mediaSource"
        static let showTrackPeek = "notch.showTrackPeek"
        static let trackPeekDuration = "notch.trackPeekDuration"
        static let showCalendar = "notch.showCalendar"
        static let calendarHours = "notch.calendarHours"
        static let hoverTolerance = "notch.hoverTolerance"
        static let showClock = "notch.showClock"
        static let showBattery = "notch.showBattery"
    }
    private let defaults: UserDefaults
    @Published var collapsedWidth: Double { didSet { defaults.set(collapsedWidth, forKey: Key.collapsedWidth) } }
    @Published var expandedWidth: Double { didSet { defaults.set(expandedWidth, forKey: Key.expandedWidth) } }
    @Published var expandedHeight: Double { didSet { defaults.set(expandedHeight, forKey: Key.expandedHeight) } }
    @Published var expandOnHover: Bool { didSet { defaults.set(expandOnHover, forKey: Key.expandOnHover) } }
    @Published var autoCollapse: Bool { didSet { defaults.set(autoCollapse, forKey: Key.autoCollapse) } }
    @Published var collapseDelay: Double { didSet { defaults.set(collapseDelay, forKey: Key.collapseDelay) } }
    @Published var cornerRadius: Double { didSet { defaults.set(cornerRadius, forKey: Key.cornerRadius) } }
    @Published var showAccent: Bool { didSet { defaults.set(showAccent, forKey: Key.showAccent) } }
    @Published var showMedia: Bool { didSet { defaults.set(showMedia, forKey: Key.showMedia) } }
    @Published var mediaSource: BoringNotchMediaSource { didSet { defaults.set(mediaSource.rawValue, forKey: Key.mediaSource) } }
    @Published var showTrackPeek: Bool { didSet { defaults.set(showTrackPeek, forKey: Key.showTrackPeek) } }
    @Published var trackPeekDuration: Double { didSet { defaults.set(trackPeekDuration, forKey: Key.trackPeekDuration) } }
    @Published var showCalendar: Bool { didSet { defaults.set(showCalendar, forKey: Key.showCalendar) } }
    @Published var calendarHours: Double { didSet { defaults.set(calendarHours, forKey: Key.calendarHours) } }
    /// How far outside the closed cutout the pointer still counts as "on the notch". 0 = cutout only.
    @Published var hoverTolerance: Double { didSet { defaults.set(hoverTolerance, forKey: Key.hoverTolerance) } }
    @Published var showClock: Bool { didSet { defaults.set(showClock, forKey: Key.showClock) } }
    @Published var showBattery: Bool { didSet { defaults.set(showBattery, forKey: Key.showBattery) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsedWidth = defaults.object(forKey: Key.collapsedWidth) as? Double ?? 220
        expandedWidth = defaults.object(forKey: Key.expandedWidth) as? Double ?? 560
        expandedHeight = defaults.object(forKey: Key.expandedHeight) as? Double ?? 132
        expandOnHover = defaults.object(forKey: Key.expandOnHover) as? Bool ?? true
        autoCollapse = defaults.object(forKey: Key.autoCollapse) as? Bool ?? true
        collapseDelay = defaults.object(forKey: Key.collapseDelay) as? Double ?? 0.5
        cornerRadius = defaults.object(forKey: Key.cornerRadius) as? Double ?? 22
        showAccent = defaults.object(forKey: Key.showAccent) as? Bool ?? true
        showMedia = defaults.object(forKey: Key.showMedia) as? Bool ?? true
        mediaSource = BoringNotchMediaSource(rawValue: defaults.string(forKey: Key.mediaSource) ?? "") ?? .automatic
        showTrackPeek = defaults.object(forKey: Key.showTrackPeek) as? Bool ?? true
        trackPeekDuration = defaults.object(forKey: Key.trackPeekDuration) as? Double ?? 4
        showCalendar = defaults.object(forKey: Key.showCalendar) as? Bool ?? true
        calendarHours = defaults.object(forKey: Key.calendarHours) as? Double ?? 24
        hoverTolerance = defaults.object(forKey: Key.hoverTolerance) as? Double ?? 0
        showClock = defaults.object(forKey: Key.showClock) as? Bool ?? true
        showBattery = defaults.object(forKey: Key.showBattery) as? Bool ?? true
    }
}

final class BoringBatteryModel: ObservableObject {
    static let shared = BoringBatteryModel()
    @Published private(set) var percent: Int = 0
    @Published private(set) var charging = false
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            Log.error("notch battery: IOPSCopyPowerSourcesInfo returned nil")
            return
        }
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            let current = info[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let capacity = info[kIOPSMaxCapacityKey as String] as? Int ?? 100
            percent = capacity > 0 ? Int((Double(current) / Double(capacity) * 100).rounded()) : 0
            charging = (info[kIOPSPowerSourceStateKey as String] as? String) == (kIOPSACPowerValue as String)
            return
        }
    }
}

struct BoringNowPlaying: Equatable {
    let source: BoringNotchMediaSource
    let title: String
    let artist: String
    let playing: Bool
    let duration: Double
    let position: Double
    let artworkURL: URL?

    var identity: String { "\(source.rawValue)|\(title)|\(artist)" }
}

final class BoringNowPlayingModel: ObservableObject {
    static let shared = BoringNowPlayingModel()
    @Published private(set) var item: BoringNowPlaying?
    @Published private(set) var artwork: NSImage?
    private let queue = DispatchQueue(label: "FreeKit.BoringNotch.NowPlaying")
    private var timer: Timer?
    private var refreshing = false

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func togglePlayback() { runCommand("playpause") }
    func previous() { runCommand("previous track") }
    func next() { runCommand("next track") }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let preference = BoringNotchPreferences.shared.mediaSource
        queue.async { [weak self] in
            let result = Self.readNowPlaying(preference: preference)
            DispatchQueue.main.async {
                let changed = self?.item?.identity != result?.identity
                self?.item = result
                self?.refreshing = false
                if changed { self?.loadArtwork(for: result) }
            }
        }
    }

    private func runCommand(_ command: String) {
        guard let source = item?.source else { return }
        let appName = source == .spotify ? "Spotify" : "Music"
        queue.async { [weak self] in
            _ = Self.runAppleScript("tell application \"\(appName)\" to \(command)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.refresh() }
        }
    }

    private static func readNowPlaying(preference: BoringNotchMediaSource) -> BoringNowPlaying? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let sources: [BoringNotchMediaSource]
        switch preference {
        case .automatic: sources = [.spotify, .appleMusic]
        case .spotify: sources = [.spotify]
        case .appleMusic: sources = [.appleMusic]
        }
        var fallback: BoringNowPlaying?
        for source in sources {
            let bundleID = source == .spotify ? "com.spotify.client" : "com.apple.Music"
            guard running.contains(bundleID), let item = read(source: source) else { continue }
            if item.playing { return item }
            fallback = fallback ?? item
        }
        return fallback
    }

    private static func read(source: BoringNotchMediaSource) -> BoringNowPlaying? {
        let appName = source == .spotify ? "Spotify" : "Music"
        let script = """
        tell application "\(appName)"
            if player state is stopped then return ""
            set currentName to name of current track
            set currentArtist to artist of current track
            set currentState to player state as text
            set currentDuration to duration of current track as string
            set currentPosition to player position as string
            set currentArtwork to ""
            if "\(appName)" is "Spotify" then set currentArtwork to artwork url of current track
            return currentName & "|||" & currentArtist & "|||" & currentState & "|||" & currentDuration & "|||" & currentPosition & "|||" & currentArtwork
        end tell
        """
        guard let value = runAppleScript(script), !value.isEmpty else { return nil }
        let parts = value.components(separatedBy: "|||")
        guard parts.count == 6 else { return nil }
        let duration = (Double(parts[3]) ?? 0) / (source == .spotify ? 1000 : 1)
        return BoringNowPlaying(source: source, title: parts[0], artist: parts[1],
                                playing: parts[2].localizedCaseInsensitiveContains("playing"),
                                duration: duration, position: Double(parts[4]) ?? 0,
                                artworkURL: URL(string: parts[5]))
    }

    private func loadArtwork(for item: BoringNowPlaying?) {
        artwork = nil
        guard let item else { return }
        queue.async { [weak self] in
            let image: NSImage?
            if let url = item.artworkURL, let data = try? Data(contentsOf: url) {
                image = NSImage(data: data)
            } else if item.source == .appleMusic {
                var error: NSDictionary?
                let descriptor = NSAppleScript(
                    source: "tell application \"Music\" to get raw data of artwork 1 of current track")?
                    .executeAndReturnError(&error)
                if let data = descriptor?.data {
                    image = NSImage(data: data)
                } else {
                    image = nil
                }
            } else {
                image = nil
            }
            DispatchQueue.main.async {
                guard self?.item?.identity == item.identity else { return }
                self?.artwork = image
            }
        }
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Log.error("notch media: \(error)"); return nil }
        return result?.stringValue
    }
}

struct BoringCalendarItem: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let calendarName: String
    let color: NSColor
}

final class BoringCalendarModel: ObservableObject {
    static let shared = BoringCalendarModel()
    @Published private(set) var upcomingEvents: [BoringCalendarItem] = []
    @Published private(set) var authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    private let store = EKEventStore()
    private var timer: Timer?
    var hasAccess: Bool { authorizationStatus == .fullAccess }

    func start() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus == .notDetermined { requestAccess() }
        else if hasAccess { refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                self?.refresh()
            }
        }
    }
    func refresh() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            upcomingEvents = []
            return
        }
        let now = Date()
        let end = now.addingTimeInterval(max(1, min(72, BoringNotchPreferences.shared.calendarHours)) * 3600)
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
        upcomingEvents = events.map {
            BoringCalendarItem(id: $0.eventIdentifier ?? UUID().uuidString,
                               title: $0.title ?? "Untitled Event", startDate: $0.startDate,
                               calendarName: $0.calendar.title,
                               color: NSColor(cgColor: $0.calendar.cgColor) ?? .systemMint)
        }
    }
}

final class BoringNotchModule: AppModule {
    let info = ModuleCatalog.boringNotch
    private lazy var controller = BoringNotchPanelController(preferences: .shared)
    private lazy var settingsWindow = ModuleSettingsWindowController(
        info: info, contentSize: NSSize(width: 600, height: 680),
        minimumSize: NSSize(width: 540, height: 440)) { AnyView(BoringNotchSettingsPane()) }
    init(registry: ModuleRegistry) {}
    func activate() { controller.show() }
    func deactivate() { controller.hide() }
    func setMenuBarItemVisible(_ visible: Bool) {}
    var settingsStyle: ModuleSettingsStyle { .window }
    func makeSettingsPane() -> AnyView { AnyView(BoringNotchSettingsPane()) }
    func openSettings() { settingsWindow.show() }
}

final class BoringNotchPanelState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var hasPhysicalNotch = false
    @Published var physicalNotchWidth: CGFloat = 0
    @Published var physicalNotchHeight: CGFloat = 0
    @Published var peeking = false
    @Published var openSize: CGSize = .zero
    @Published var closedSize: CGSize = .zero
    @Published var peekSize: CGSize = .zero

    var currentSize: CGSize { expanded ? openSize : (peeking ? peekSize : closedSize) }
}

enum NotchMetrics {
    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 14
    static let openTopRadius: CGFloat = 19
    static let openBottomRadius: CGFloat = 24
    /// Slack around the shape so its flared shoulders stay inside the window.
    static let windowPadding: CGFloat = 24
}

/// The top corners curve *outward* into the menu bar rather than in, so the panel reads as the
/// physical cutout growing instead of a rectangle parked beneath it. Ported from boring.notch.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = min(topCornerRadius, rect.width / 2)
        let bottom = min(bottomCornerRadius, max(0, rect.width / 2 - top), rect.height)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

final class BoringNotchPanelController {
    private let panel: NSPanel
    private let preferences: BoringNotchPreferences
    private let coordinator = OverlayLayoutCoordinator.shared
    private let state = BoringNotchPanelState()
    private let media = BoringNowPlayingModel.shared
    private let calendar = BoringCalendarModel.shared
    private let battery = BoringBatteryModel.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var collapseWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var isExpanded: Bool { state.expanded }

    init(preferences: BoringNotchPreferences) {
        self.preferences = preferences
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // macOS renders a light rim around a borderless panel's shadow, which reads as a
        // hairline border tracing the notch. The notch must look like screen bezel, so: none.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Empty space around the shape has no SwiftUI view in it, so it never hit-tests and clicks
        // fall through to the menu bar underneath. Do not add a full-size background here.
        panel.contentView = NSHostingView(rootView: BoringNotchPanelView(
            preferences: preferences, state: state, media: media, calendar: calendar,
            onToggle: { [weak self] in self?.setExpanded(!(self?.isExpanded ?? false)) },
            onPin: { [weak self] in self?.state.pinned.toggle() },
            onHover: { [weak self] in self?.handleHover($0) }))
        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateFrame(animated: true)
                self.preferences.showMedia ? self.media.start() : self.media.stop()
                self.preferences.showCalendar ? self.calendar.start() : self.calendar.stop()
                self.preferences.showBattery ? self.battery.start() : self.battery.stop()
                self.media.refresh()
                self.calendar.refresh()
            }
        }.store(in: &subscriptions)
        coordinator.$menuTriggerFrame.combineLatest(coordinator.$menuBarActive)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateFrame(animated: true) } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateFrame(animated: false) } }
            .store(in: &subscriptions)
        media.$item.compactMap { $0 }.map(\.identity).removeDuplicates()
            .sink { [weak self] _ in self?.showTrackPeek() }
            .store(in: &subscriptions)
    }

    func show() {
        updateFrame(animated: false); panel.orderFrontRegardless()
        if preferences.showMedia { media.start() }
        if preferences.showCalendar { calendar.start() }
        if preferences.showBattery { battery.start() }
    }
    func hide() {
        collapseWork?.cancel(); peekWork?.cancel(); media.stop(); calendar.stop(); battery.stop()
        panel.orderOut(nil); coordinator.clearNotch()
    }
    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        collapseWork?.cancel()
        if expanded { peekWork?.cancel(); state.peeking = false }
        state.expanded = expanded
        updateFrame(animated: true)
    }
    private func showTrackPeek() {
        guard preferences.showTrackPeek, panel.isVisible, !isExpanded else { return }
        peekWork?.cancel()
        state.peeking = true
        updateFrame(animated: true)
        let work = DispatchWorkItem { [weak self] in
            self?.state.peeking = false
            self?.updateFrame(animated: true)
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(1.5, min(8, preferences.trackPeekDuration)),
            execute: work)
    }
    private func handleHover(_ hovering: Bool) {
        guard preferences.expandOnHover else { return }
        collapseWork?.cancel()
        if hovering { setExpanded(true) }
        else if preferences.autoCollapse, !state.pinned {
            let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, min(5, preferences.collapseDelay)),
                                          execute: work)
        }
    }
    /// The window itself never animates — it is parked at open size and the shape springs inside it.
    /// Animating an NSWindow frame cannot spring and always reads as stiff.
    private func updateFrame(animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let hasNotch = !left.isEmpty && !right.isEmpty && right.minX > left.maxX
        let notchWidth = hasNotch ? right.minX - left.maxX : 0
        let notchHeight = hasNotch ? max(screen.safeAreaInsets.top, left.height, right.height) : 0
        let centerX = hasNotch ? (left.maxX + right.minX) / 2 : screen.frame.midX
        state.hasPhysicalNotch = hasNotch
        state.physicalNotchWidth = notchWidth
        state.physicalNotchHeight = notchHeight

        let minWidth = max(notchWidth + 80, 420)
        var openWidth = max(minWidth, min(760, preferences.expandedWidth))
        let trigger = coordinator.menuTriggerFrame
        if !trigger.isEmpty {
            let available = trigger.midX > centerX
                ? 2 * (trigger.minX - centerX - 8) : 2 * (centerX - trigger.maxX - 8)
            openWidth = min(openWidth, max(minWidth, available))
        }
        let closedHeight = hasNotch ? notchHeight : max(30, screen.safeAreaInsets.top)
        let openHeight = closedHeight + max(112, min(200, preferences.expandedHeight))
        state.openSize = CGSize(width: openWidth, height: openHeight)
        state.closedSize = CGSize(
            width: hasNotch
                ? notchWidth + 2 * NotchMetrics.closedTopRadius
                : max(140, min(340, preferences.collapsedWidth)),
            height: closedHeight)
        state.peekSize = CGSize(width: min(openWidth, state.closedSize.width + 220), height: closedHeight)

        let pad = NotchMetrics.windowPadding
        let frame = NSRect(x: centerX - (openWidth + 2 * pad) / 2,
                           y: screen.frame.maxY - (openHeight + pad),
                           width: openWidth + 2 * pad, height: openHeight + pad)
        if frame != panel.frame { panel.setFrame(frame, display: panel.isVisible) }
        publishNotchRect(screen: screen, centerX: centerX)
    }

    /// The window is much larger than the visible shape, so report the shape's rect — not the
    /// window's — or every other overlay will route around empty space.
    private func publishNotchRect(screen: NSScreen, centerX: CGFloat) {
        let size = isExpanded ? state.openSize : (state.peeking ? state.peekSize : state.closedSize)
        let rect = NSRect(x: centerX - size.width / 2, y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height)
        coordinator.updateNotch(frame: rect, expanded: isExpanded)
    }
}

struct BoringNotchPanelView: View {
    @ObservedObject var preferences: BoringNotchPreferences
    @ObservedObject var state: BoringNotchPanelState
    @ObservedObject var media: BoringNowPlayingModel
    @ObservedObject var calendar: BoringCalendarModel
    @ObservedObject var battery = BoringBatteryModel.shared
    let onToggle: () -> Void
    let onPin: () -> Void
    let onHover: (Bool) -> Void
    private var shape: NotchShape {
        NotchShape(
            topCornerRadius: state.expanded ? NotchMetrics.openTopRadius : NotchMetrics.closedTopRadius,
            bottomCornerRadius: state.expanded
                ? CGFloat(max(12, min(34, preferences.cornerRadius)))
                : NotchMetrics.closedBottomRadius)
    }
    // Expand/collapse consumes the shared critically damped grammar so the notch reads physical, never bouncy.
    private var expandAnimation: Animation? { DS.animExpand() }
    /// Only widen the hover target while closed — once open the panel is its own target.
    private var hoverTolerance: CGFloat {
        state.expanded ? 0 : CGFloat(max(0, min(40, preferences.hoverTolerance)))
    }
    var body: some View {
        // Sits at the top of an oversized window. Only this sized view exists, so the empty margin
        // around it never hit-tests and clicks pass through to the menu bar.
        Group {
            if state.expanded { expandedContent.transition(.dsCrossfade) }
            else { collapsedContent.transition(.dsCrossfade) }
        }
            // Content swap crossfades on the shorter grammar timing, independent of the shape's spring.
            .animation(DS.animCrossfade, value: state.expanded)
            .frame(width: state.currentSize.width, height: state.currentSize.height)
            .background(Color.black, in: shape)
            .clipShape(shape)
            // Hover target grows beyond the visible shape only if the user asks for it; at the
            // default of 0 the pointer must be on the cutout itself, not merely near it.
            .frame(width: state.currentSize.width + 2 * hoverTolerance,
                   height: state.currentSize.height + hoverTolerance,
                   alignment: .top)
            .contentShape(Rectangle())
            .onHover(perform: onHover)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(expandAnimation, value: state.expanded)
            .animation(expandAnimation, value: state.peeking)
            .animation(expandAnimation, value: state.currentSize)
    }
    private var collapsedContent: some View {
        Group {
            if state.hasPhysicalNotch {
                if state.peeking {
                    sneakPeek
                } else if preferences.showAccent {
                    VStack { Spacer(); Capsule().fill(Color.dsAccent.opacity(0.8))
                        .frame(width: 28, height: 2).padding(.bottom, 3) }
                } else {
                    Color.clear
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: media.item?.playing == true ? "waveform" : "play.fill").foregroundStyle(Color.dsAccent)
                    Text(media.item?.title ?? "No audio playing").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75)).lineLimit(1)
                    Spacer()
                }.padding(.horizontal, 12)
            }
        }.contentShape(Rectangle()).onTapGesture(perform: onToggle)
    }
    private var sneakPeek: some View {
        HStack(spacing: 0) {
            artworkView(size: 28)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
            Color.clear.frame(width: state.physicalNotchWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(media.item?.title ?? "Now Playing")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(media.item?.artist ?? "")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
        }
        .padding(.horizontal, 8)
    }
    /// Clock and battery flank the cutout in the strip it occupies — the only row where the notch
    /// steals horizontal space, so it may as well earn it.
    private var headerStrip: some View {
        HStack(spacing: 0) {
            Group {
                if preferences.showClock {
                    TimelineView(.everyMinute) { context in
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: state.physicalNotchWidth)
            Group {
                if preferences.showBattery {
                    HStack(spacing: 5) {
                        Text("\(battery.percent)%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.85))
                        Image(systemName: battery.charging ? "battery.100.bolt" : batterySymbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(battery.charging ? Color.dsAccent : Color.white.opacity(0.7))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: state.hasPhysicalNotch ? state.physicalNotchHeight : 22)
    }
    private var batterySymbol: String {
        switch battery.percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
    private var expandedContent: some View {
        VStack(spacing: 0) {
            // The physical cutout owns this strip; the clock and battery fill the space beside it.
            headerStrip
                .padding(.horizontal, NotchMetrics.openTopRadius + 11)
            HStack(alignment: .center, spacing: 18) {
                if preferences.showMedia {
                    mediaWing.frame(maxWidth: .infinity, alignment: .leading)
                }
                if preferences.showCalendar {
                    if preferences.showMedia {
                        Rectangle().fill(Color.white.opacity(0.06))
                            .frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 4)
                    }
                    calendarWing.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxHeight: .infinity)
            // The shape's straight edges sit `openTopRadius` inboard of the frame — clear them.
            .padding(.horizontal, NotchMetrics.openTopRadius + 11)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .overlay(alignment: .bottom) {
            Button(action: onPin) { Image(systemName: state.pinned ? "pin.fill" : "pin")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(state.pinned ? Color.dsAccent : Color.white.opacity(0.22))
                .frame(width: 20, height: 14) }
                .buttonStyle(.plain).help(state.pinned ? "Unpin Notch" : "Keep Notch Open")
        }
    }
    private var mediaWing: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                artworkView(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.item?.title ?? "Nothing Playing").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white).lineLimit(1)
                    Text(media.item?.artist ?? "Open Spotify or Music").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.42)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            scrubber.opacity(media.item == nil ? 0.3 : 1)
            HStack(spacing: 0) {
                Text(playbackTime(media.item?.position ?? 0))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    playerButton("backward.fill", help: "Previous", action: media.previous)
                    playerButton(media.item?.playing == true ? "pause.fill" : "play.fill",
                                 help: media.item?.playing == true ? "Pause" : "Play",
                                 action: media.togglePlayback, prominent: true)
                    playerButton("forward.fill", help: "Next", action: media.next)
                }
                .fixedSize()
                .disabled(media.item == nil).opacity(media.item == nil ? 0.3 : 1)
                Text("-" + playbackTime(max(0, (media.item?.duration ?? 0) - (media.item?.position ?? 0))))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
    private var scrubber: some View {
        GeometryReader { geo in
            let duration = max(1, media.item?.duration ?? 1)
            let fraction = min(1, max(0, (media.item?.position ?? 0) / duration))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(Color.dsAccent).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        if let artwork = media.artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: min(8, size / 5), style: .continuous))
        } else {
            Image(systemName: media.item?.source == .spotify
                  ? "dot.radiowaves.left.and.right" : "music.note")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(Color.dsAccent)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: min(8, size / 5), style: .continuous))
        }
    }
    private func playbackTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    private func playerButton(_ symbol: String, help: String, action: @escaping () -> Void,
                              prominent: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 11 : 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(prominent ? 0.95 : 0.6))
                .frame(width: prominent ? 26 : 22, height: prominent ? 26 : 22)
                .background(prominent ? Color.white.opacity(0.10) : Color.clear, in: Circle())
        }.buttonStyle(.plain).help(help)
    }
    private var calendarWing: some View {
        VStack(alignment: .trailing, spacing: 7) {
            Text("UP NEXT")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(0.6)
                .foregroundStyle(Color.white.opacity(0.28))
            if calendar.upcomingEvents.isEmpty {
                Text(calendar.hasAccess ? "Nothing upcoming" : "Calendar access off")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.white.opacity(0.4))
            } else {
                ForEach(Array(calendar.upcomingEvents.prefix(2))) { event in
                    HStack(spacing: 8) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(event.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                Text(event.startDate, format: .dateTime.hour().minute())
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                Text(event.calendarName).lineLimit(1)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Color.white.opacity(0.38))
                        }
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color(nsColor: event.color))
                            .frame(width: 3, height: 26)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

struct BoringNotchSettingsPane: View {
    @ObservedObject private var preferences = BoringNotchPreferences.shared
    @ObservedObject private var calendar = BoringCalendarModel.shared
    private var hasPhysicalNotch: Bool {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        let left = screen.auxiliaryTopLeftArea ?? .zero, right = screen.auxiliaryTopRightArea ?? .zero
        return !left.isEmpty && !right.isEmpty && right.minX > left.maxX
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DSSettingsCard(title: "Preview") { BoringNotchPreview().frame(maxWidth: .infinity).frame(height: 128) }
            DSSettingsCard(title: "Player") {
                DSToggleRow(title: "Show media controls", isOn: $preferences.showMedia)
                HStack(spacing: 8) { ForEach(BoringNotchMediaSource.allCases) { source in
                    DSChip(title: source.rawValue, selected: preferences.mediaSource == source) {
                        preferences.mediaSource = source; BoringNowPlayingModel.shared.refresh()
                    }
                }}
                DSToggleRow(title: "Peek when the track changes", isOn: $preferences.showTrackPeek)
                slider("Peek duration", value: $preferences.trackPeekDuration, range: 1.5...8, suffix: "s")
            }
            DSSettingsCard(title: "Calendar") {
                DSToggleRow(title: "Show next event", isOn: $preferences.showCalendar)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(calendar.hasAccess ? "Calendar connected" : "Calendar access required")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsPaper)
                        Text("Includes Google accounts connected to macOS Calendar.")
                            .font(.system(size: 10)).foregroundStyle(Color.dsFaint)
                    }
                    Spacer()
                    if !calendar.hasAccess { Button("Allow Calendar") { calendar.requestAccess() }.buttonStyle(GhostButtonStyle()) }
                }
                slider("Look ahead", value: $preferences.calendarHours, range: 1...72, suffix: "h")
            }
            DSSettingsCard(title: "Dimensions") {
                if hasPhysicalNotch {
                    HStack(spacing: 10) { Image(systemName: "macbook").foregroundStyle(Color.dsAccent).frame(width: 24)
                        Text("Collapsed size follows this MacBook's camera cutout.")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsPaper) }
                } else { slider("Collapsed width", value: $preferences.collapsedWidth, range: 140...340) }
                slider("Expanded width", value: $preferences.expandedWidth, range: 380...760)
                slider("Content height", value: $preferences.expandedHeight, range: 112...200)
                slider("Corner radius", value: $preferences.cornerRadius, range: 12...34)
            }
            DSSettingsCard(title: "Menu bar strip") {
                DSToggleRow(title: "Show clock", isOn: $preferences.showClock)
                DSToggleRow(title: "Show battery", isOn: $preferences.showBattery)
            }
            DSSettingsCard(title: "Behavior") {
                DSToggleRow(title: "Expand on hover", isOn: $preferences.expandOnHover)
                VStack(alignment: .leading, spacing: 2) {
                    slider("Hover reach", value: $preferences.hoverTolerance, range: 0...40)
                    Text(preferences.hoverTolerance < 1
                         ? "Expands only when the pointer is on the notch itself."
                         : "Expands within \(Int(preferences.hoverTolerance))pt of the notch.")
                        .font(.system(size: 10)).foregroundStyle(Color.dsFaint)
                }
                DSToggleRow(title: "Collapse after leaving", isOn: $preferences.autoCollapse)
                slider("Collapse delay", value: $preferences.collapseDelay, range: 0.2...5, suffix: "s")
                DSToggleRow(title: "Show accent indicator", isOn: $preferences.showAccent)
            }
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String = "pt") -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsPaper)
                .frame(width: 112, alignment: .leading)
            Slider(value: value, in: range).tint(Color.dsAccent)
            Text(suffix == "s" ? String(format: "%.1fs", value.wrappedValue) : "\(Int(value.wrappedValue))\(suffix)")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.dsMuted)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

private struct BoringNotchPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("12:19")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                NotchShape(topCornerRadius: 4, bottomCornerRadius: 7)
                    .fill(Color.dsInk0)
                    .frame(width: 132, height: 26)
                HStack(spacing: 4) {
                    Text("85%").font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Image(systemName: "battery.75").font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 26)
            .padding(.horizontal, 14)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .foregroundStyle(Color.dsAccent)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Song title").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.white)
                            Text("Artist").font(.system(size: 8)).foregroundStyle(Color.white.opacity(0.45))
                        }
                    }
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10)).frame(height: 2)
                        Capsule().fill(Color.dsAccent).frame(width: 62, height: 2)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "backward.fill")
                        Image(systemName: "pause.fill")
                        Image(systemName: "forward.fill")
                    }.font(.system(size: 8)).foregroundStyle(Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                VStack(alignment: .trailing, spacing: 5) {
                    Text("UP NEXT").font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .kerning(0.6).foregroundStyle(Color.white.opacity(0.28))
                    previewEvent("Design review", "10:30 AM")
                    previewEvent("Project sync", "1:00 PM")
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
        }
        .frame(width: 380, height: 130).background(Color.black,
            in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 18,
                bottomTrailingRadius: 18, topTrailingRadius: 0, style: .continuous))
    }

    private func previewEvent(_ title: String, _ time: String) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.white.opacity(0.8))
                Text(time).font(.system(size: 7, design: .monospaced)).foregroundStyle(Color.white.opacity(0.4))
            }
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.dsAccent).frame(width: 2.5, height: 22)
        }
    }
}
