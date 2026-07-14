import AppKit
import AVFoundation
import Combine
import CoreImage
import EventKit
import IOKit.ps
import SwiftUI
import FreeKitCore

enum BoringNotchMediaSource: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    var id: String { rawValue }
}

/// What the virtual (non-notch) collapsed bar shows at rest. Physical notches keep their
/// own accent-dot/clear behavior below the camera cutout; this only governs displays with
/// no real cutout to fall back on, where a dead placeholder is the difference between the
/// notch reading as useful vs. reading as a blank bar most of the day.
enum BoringNotchCollapsedContent: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing"
    case clock = "Clock"
    case accent = "Accent Dot"
    case minimal = "Minimal"
    var id: String { rawValue }
}

/// The glanceable readouts eligible for the header strip's leading side. Exactly two show at
/// a time — the strip beside the cutout is narrow, and two readouts is the most it can hold
/// without crowding the app buttons on the other side.
enum BoringNotchGlanceItem: String, CaseIterable, Identifiable {
    case time = "Time"
    case cpu = "CPU"
    case memory = "Memory"
    case battery = "Battery"
    var id: String { rawValue }
}

/// How the calendar wing lays out upcoming events. List is the original two-line-per-event
/// layout; Compact trades detail for count (more events, one line each); Agenda leads with a
/// large "time until" readout for the very next event, the way a glance at a real notch app
/// (Notchable, NotchNook) tends to foreground urgency over a flat list.
enum BoringNotchCalendarStyle: String, CaseIterable, Identifiable {
    // Upstream TheBoredTeam/boring.notch look: month/year block, a small
    // day picker, and colored-bar event rows with start/end times.
    case boring = "Boring"
    case list = "List"
    case compact = "Compact"
    case agenda = "Agenda"
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
        static let calendarStyle = "notch.calendarStyle"
        static let hoverTolerance = "notch.hoverTolerance"
        static let glanceItems = "notch.glanceItems"
        static let showMirrorButton = "notch.showMirrorButton"
        static let collapsedContent = "notch.collapsedContent"
        static let mediaWingLeading = "notch.mediaWingLeading"
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
    @Published var calendarStyle: BoringNotchCalendarStyle {
        didSet { defaults.set(calendarStyle.rawValue, forKey: Key.calendarStyle) }
    }
    /// How far outside the closed cutout the pointer still counts as "on the notch". 0 = cutout only.
    @Published var hoverTolerance: Double { didSet { defaults.set(hoverTolerance, forKey: Key.hoverTolerance) } }
    /// The (at most two) readouts on the header strip's leading side, in display order.
    @Published var glanceItems: [BoringNotchGlanceItem] {
        didSet { defaults.set(glanceItems.map(\.rawValue), forKey: Key.glanceItems) }
    }
    // Off by default: this gates a camera-permission prompt, so it should never fire
    // without the user explicitly opting in first.
    @Published var showMirrorButton: Bool {
        didSet { defaults.set(showMirrorButton, forKey: Key.showMirrorButton) }
    }
    @Published var collapsedContent: BoringNotchCollapsedContent {
        didSet { defaults.set(collapsedContent.rawValue, forKey: Key.collapsedContent) }
    }
    @Published var mediaWingLeading: Bool { didSet { defaults.set(mediaWingLeading, forKey: Key.mediaWingLeading) } }

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
        calendarStyle = BoringNotchCalendarStyle(
            rawValue: defaults.string(forKey: Key.calendarStyle) ?? "") ?? .boring
        hoverTolerance = defaults.object(forKey: Key.hoverTolerance) as? Double ?? 0
        let storedGlance = (defaults.stringArray(forKey: Key.glanceItems) ?? [])
            .compactMap(BoringNotchGlanceItem.init(rawValue:))
        glanceItems = storedGlance.isEmpty ? [.time, .battery] : Array(storedGlance.prefix(2))
        showMirrorButton = defaults.object(forKey: Key.showMirrorButton) as? Bool ?? false
        collapsedContent = BoringNotchCollapsedContent(
            rawValue: defaults.string(forKey: Key.collapsedContent) ?? "") ?? .nowPlaying
        mediaWingLeading = defaults.object(forKey: Key.mediaWingLeading) as? Bool ?? true
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

/// Compact CPU/Memory glance for the header strip — reuses the same `StatsSampler` the
/// Stats module's full menu-bar readouts are built on, so this is a second, independent
/// cheap poll rather than new sampling logic.
final class BoringStatsGlanceModel: ObservableObject {
    static let shared = BoringStatsGlanceModel()
    @Published private(set) var cpuUsage: Double = 0        // 0...1
    @Published private(set) var memoryFraction: Double = 0  // 0...1
    private let sampler = StatsSampler()
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        let snapshot = sampler.sample()
        cpuUsage = snapshot.cpuUsage
        memoryFraction = snapshot.memoryTotal > 0 ? snapshot.memoryUsed / snapshot.memoryTotal : 0
    }
}

/// Quick front-camera preview — boringNotch's own headline "Quick Mirror" feature: a fast
/// look before a call, without opening Photo Booth or FaceTime. The session only ever runs
/// while the mirror is actually open, and stops the moment the notch collapses.
final class BoringMirrorModel: ObservableObject {
    static let shared = BoringMirrorModel()
    @Published private(set) var isRunning = false
    @Published private(set) var authorizationDenied = false
    let session = AVCaptureSession()
    private var configured = false

    func start() {
        guard Permissions.cameraAuthorized() else {
            Permissions.requestCamera { [weak self] granted in
                guard let self else { return }
                if granted { self.start() } else { self.authorizationDenied = true }
            }
            return
        }
        authorizationDenied = false
        configureIfNeeded()
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async { self?.isRunning = true }
        }
    }

    func stop() {
        // Also clears a lingering denied banner so dismissing the mirror always
        // returns the notch to its normal expanded layout.
        authorizationDenied = false
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async { self?.isRunning = false }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .medium
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        } else {
            Log.error("notch mirror: no camera input available")
        }
        session.commitConfiguration()
    }
}

/// Hosts an `AVCaptureVideoPreviewLayer` — SwiftUI has no native camera-preview view.
private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        // A mirror should look like a mirror, not a security-cam feed of yourself.
        if let connection = nsView.previewLayer.connection, connection.isVideoMirrored != true {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}

private final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = previewLayer
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct BoringNowPlaying: Equatable {
    /// nil = detected system-wide (any app) rather than via app-specific AppleScript;
    /// transport control falls back to simulated media keys for those.
    let source: BoringNotchMediaSource?
    let appName: String
    let title: String
    let artist: String
    let playing: Bool
    let duration: Double
    let position: Double
    let artworkURL: URL?

    var identity: String { "\(appName)|\(title)|\(artist)" }
}

final class BoringNowPlayingModel: ObservableObject {
    static let shared = BoringNowPlayingModel()
    @Published private(set) var item: BoringNowPlaying?
    @Published private(set) var artwork: NSImage?
    /// Dominant color sampled from `artwork`, for the expanded wing's background wash.
    @Published private(set) var artworkTint: NSColor?
    private let queue = DispatchQueue(label: "FreeKit.BoringNotch.NowPlaying")
    private var timer: Timer?
    private var refreshing = false

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func togglePlayback() { sendTransport("playpause", key: .playPause) }
    func previous() { sendTransport("previous track", key: .previous) }
    func next() { sendTransport("next track", key: .next) }

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

    /// Spotify/Music get precise AppleScript control (already scriptable); anything found
    /// only through the system-wide reader gets a simulated hardware media key instead,
    /// since we don't have an app-specific target to script.
    private func sendTransport(_ appleScriptCommand: String, key: MediaKey) {
        guard let item else { return }
        guard let source = item.source else {
            key.post()
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
            return
        }
        let appName = source == .spotify ? "Spotify" : "Music"
        queue.async { [weak self] in
            _ = Self.runAppleScript("tell application \"\(appName)\" to \(appleScriptCommand)")
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
        if let fallback { return fallback }
        // Neither Spotify nor Music is even running: fall back to system-wide detection
        // (Safari, Podcasts, VLC, anything else) only in Automatic mode — an explicit
        // Spotify/Apple Music choice means the user wants exactly that app or nothing.
        guard preference == .automatic, let system = SystemNowPlaying.fetch() else { return nil }
        return BoringNowPlaying(source: nil, appName: system.appName, title: system.title,
                                artist: system.artist, playing: system.playing,
                                duration: system.duration, position: system.elapsed, artworkURL: nil)
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
        return BoringNowPlaying(source: source, appName: appName, title: parts[0], artist: parts[1],
                                playing: parts[2].localizedCaseInsensitiveContains("playing"),
                                duration: duration, position: Double(parts[4]) ?? 0,
                                artworkURL: URL(string: parts[5]))
    }

    private func loadArtwork(for item: BoringNowPlaying?) {
        artwork = nil
        artworkTint = nil
        guard let item else { return }
        queue.async { [weak self] in
            let image: NSImage?
            var isRealArtwork = true
            if let url = item.artworkURL, let data = try? Data(contentsOf: url) {
                image = NSImage(data: data)
            } else if item.source == nil {
                // System-wide detection has no reliable artwork source; the app's own
                // icon reads better than a blank placeholder, but it isn't album art,
                // so it shouldn't drive the background tint below.
                image = NSWorkspace.shared.runningApplications
                    .first { $0.localizedName == item.appName }?.icon
                isRealArtwork = false
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
            let tint = isRealArtwork ? image.flatMap(Self.averageColor) : nil
            DispatchQueue.main.async {
                guard self?.item?.identity == item.identity else { return }
                self?.artwork = image
                self?.artworkTint = tint
            }
        }
    }

    /// Cheap dominant-color sample (CIAreaAverage over the whole image) for the expanded
    /// wing's background wash — a hint of the album art's color, not a real palette.
    private static func averageColor(of image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
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
    let endDate: Date
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
            .prefix(5)
        upcomingEvents = events.map(Self.item(from:))
    }

    // Whole-day view for the Boring calendar style's day picker.
    func events(on day: Date) -> [BoringCalendarItem] {
        guard hasAccess else { return [] }
        let cal = Foundation.Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .prefix(10)
            .map(Self.item(from:))
    }

    private static func item(from event: EKEvent) -> BoringCalendarItem {
        BoringCalendarItem(id: event.eventIdentifier ?? UUID().uuidString,
                           title: event.title ?? "Untitled Event",
                           startDate: event.startDate, endDate: event.endDate,
                           calendarName: event.calendar.title,
                           color: NSColor(cgColor: event.calendar.cgColor) ?? .systemMint)
    }
}

final class BoringNotchModule: AppModule {
    let info = ModuleCatalog.boringNotch
    private let registry: ModuleRegistry
    private lazy var controller = BoringNotchPanelController(preferences: .shared, registry: registry)
    init(registry: ModuleRegistry) { self.registry = registry }
    func activate() { controller.show() }
    func deactivate() { controller.hide() }
    func setMenuBarItemVisible(_ visible: Bool) {}
    var settingsPopupSize: NSSize { NSSize(width: 600, height: 680) }
    func makeSettingsPane() -> AnyView { AnyView(BoringNotchSettingsPane()) }
    func openSettings() { ControlCenterPresenter.shared.present(moduleID: info.id) }
}

final class BoringNotchPanelState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var hasPhysicalNotch = false
    @Published var physicalNotchWidth: CGFloat = 0
    @Published var physicalNotchHeight: CGFloat = 0
    @Published var peeking = false
    /// Mirror open (or its permission nudge showing): the expanded shape shrinks to hug
    /// the camera preview instead of the full two-wing spread.
    @Published var mirroring = false
    @Published var openSize: CGSize = .zero
    @Published var closedSize: CGSize = .zero
    @Published var peekSize: CGSize = .zero
    @Published var mirrorSize: CGSize = .zero

    var currentSize: CGSize {
        if expanded { return mirroring ? mirrorSize : openSize }
        return peeking ? peekSize : closedSize
    }
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
// A rectangle whose bottom edge undulates in a gentle sine wave instead of
// running perfectly straight — used so the header's solid-black band meets
// the wash along an organic line rather than a ruler-straight seam. Amplitude
// 0 degrades to a plain rect (used for the collapsed pill, which has no
// wash beneath it to transition into).
private struct WavyEdgeRect: Shape {
    var amplitude: CGFloat
    var wavelength: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        guard amplitude > 0, wavelength > 0 else {
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
        // Straight segments between sample points read as faceted/jagged no
        // matter how many of them there are — routing a quad curve through
        // the midpoint of each pair instead gives an actually continuous
        // curve, the same "smooth polyline" trick used to draw smooth line
        // charts.
        let steps = max(Int(rect.width / 10), 10)
        var points: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = rect.maxX - t * rect.width
            let y = rect.maxY + amplitude * sin((x / wavelength) * 2 * .pi)
            points.append(CGPoint(x: x, y: y))
        }
        p.addLine(to: points[0])
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            p.addQuadCurve(to: mid, control: points[i - 1])
        }
        p.addLine(to: points[points.count - 1])
        p.closeSubpath()
        return p
    }
}

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

/// An `NSHostingView` that also accepts file drags, so dropping a file directly onto the
/// notch can bridge into the Shelf module instead of the notch needing its own file tray —
/// the single most-requested feature across every competing notch app (NotchNook, boring.notch).
private final class NotchDropCatcherHostingView<Content: View>: NSHostingView<Content> {
    var onDropFiles: (([URL], NSPoint) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }
    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFiles(sender) ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFiles(sender) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls, NSEvent.mouseLocation)
        return true
    }
    private func acceptsFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.types?.contains(.fileURL) == true
    }
}

final class BoringNotchPanelController {
    private let panel: NSPanel
    private let preferences: BoringNotchPreferences
    private let registry: ModuleRegistry
    private let coordinator = OverlayLayoutCoordinator.shared
    private let state = BoringNotchPanelState()
    private let media = BoringNowPlayingModel.shared
    private let calendar = BoringCalendarModel.shared
    private let battery = BoringBatteryModel.shared
    private let stats = BoringStatsGlanceModel.shared
    private let mirror = BoringMirrorModel.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var collapseWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var mirrorClickMonitors: [Any] = []
    private var isExpanded: Bool { state.expanded }

    init(preferences: BoringNotchPreferences, registry: ModuleRegistry) {
        self.preferences = preferences
        self.registry = registry
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
        let hostingView = NotchDropCatcherHostingView(rootView: BoringNotchPanelView(
            preferences: preferences, state: state, media: media, calendar: calendar,
            onToggle: { [weak self] in self?.setExpanded(!(self?.isExpanded ?? false)) },
            onPin: { [weak self] in self?.state.pinned.toggle() },
            onHover: { [weak self] in self?.handleHover($0) },
            // Same enable-on-demand behavior as the Apps tab's Open button, so
            // a notch shortcut always works even for a not-yet-enabled tool.
            onOpenModule: { [weak self] id in
                guard let registry = self?.registry,
                      let module = registry.module(id: id) else { return }
                if !registry.isEnabled(id: id) { registry.setEnabled(true, id: id) }
                module.openSettings()
            },
            onOpenTools: { ControlCenterPresenter.shared.present(section: .tools) }))
        hostingView.onDropFiles = { [weak self] urls, point in self?.handleDroppedFiles(urls, at: point) }
        panel.contentView = hostingView
        preferences.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateFrame(animated: true)
                self.preferences.showMedia ? self.media.start() : self.media.stop()
                self.preferences.showCalendar ? self.calendar.start() : self.calendar.stop()
                let glance = self.preferences.glanceItems
                glance.contains(.battery) ? self.battery.start() : self.battery.stop()
                glance.contains(.cpu) || glance.contains(.memory)
                    ? self.stats.start() : self.stats.stop()
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
        // Mirror engagement (running, or showing its permission nudge) drives the shrink-to-
        // camera shape and arms the click-anywhere-else dismissal.
        mirror.$isRunning.combineLatest(mirror.$authorizationDenied)
            .map { $0 || $1 }.removeDuplicates()
            .sink { [weak self] engaged in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.state.mirroring = engaged
                    self.updateFrame(animated: true)
                    engaged ? self.installMirrorClickMonitors() : self.removeMirrorClickMonitors()
                }
            }
            .store(in: &subscriptions)
    }

    /// Any click that isn't on the notch panel (the mirror itself) dismisses the mirror —
    /// a global monitor catches clicks landing in other apps, a local one clicks on our
    /// own other windows. Clicks on the panel pass through untouched.
    private func installMirrorClickMonitors() {
        removeMirrorClickMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in self?.mirror.stop() }) {
            mirrorClickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
                if let self, event.window !== self.panel { self.mirror.stop() }
                return event
            }) {
            mirrorClickMonitors.append(local)
        }
    }
    private func removeMirrorClickMonitors() {
        mirrorClickMonitors.forEach(NSEvent.removeMonitor)
        mirrorClickMonitors = []
    }

    func show() {
        updateFrame(animated: false); panel.orderFrontRegardless()
        if preferences.showMedia { media.start() }
        if preferences.showCalendar { calendar.start() }
        if preferences.glanceItems.contains(.battery) { battery.start() }
        if preferences.glanceItems.contains(where: { $0 == .cpu || $0 == .memory }) { stats.start() }
    }
    func hide() {
        collapseWork?.cancel(); peekWork?.cancel()
        media.stop(); calendar.stop(); battery.stop(); stats.stop(); mirror.stop()
        removeMirrorClickMonitors()
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
        // While the mirror is up, dismissal belongs to the click-away monitors — leaning
        // back to look at yourself shouldn't collapse the panel out from under the camera.
        else if preferences.autoCollapse, !state.pinned, !state.mirroring {
            let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, min(5, preferences.collapseDelay)),
                                          execute: work)
        }
    }
    // Only bridges to Shelf if that module is actually enabled — dropping a file on the
    // notch shouldn't summon a tool the user turned off.
    private func handleDroppedFiles(_ urls: [URL], at point: NSPoint) {
        guard registry.isEnabled(id: ModuleCatalog.shelf.id),
              let shelf = registry.module(id: ModuleCatalog.shelf.id) as? ShelfModule else { return }
        shelf.addToShelf(urls, near: point)
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
        // Mirror mode hugs the camera feed: same height as the open panel, but only as wide
        // as a 4:3 preview (the built-in camera's aspect at the .medium preset) needs — never
        // narrower than the physical cutout plus its flared shoulders.
        let mirrorContentHeight = openHeight - closedHeight
        state.mirrorSize = CGSize(
            width: min(openWidth,
                       max(notchWidth + 2 * NotchMetrics.openTopRadius,
                           mirrorContentHeight * 4 / 3 + 24)),
            height: openHeight)

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
        let size = state.currentSize
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
    @ObservedObject var stats = BoringStatsGlanceModel.shared
    @ObservedObject var mirror = BoringMirrorModel.shared
    let onToggle: () -> Void
    let onPin: () -> Void
    let onHover: (Bool) -> Void
    let onOpenModule: (String) -> Void
    let onOpenTools: () -> Void
    @State private var selectedCalendarDay = Date()
    // The app-like tools worth one-tap access from the notch; kept short so
    // the bottom row stays quieter than the media controls above it.
    private static let appShortcuts: [ModuleInfo] = ModuleCatalog.apps
    private var shape: NotchShape {
        if state.expanded {
            return NotchShape(topCornerRadius: NotchMetrics.openTopRadius,
                              bottomCornerRadius: CGFloat(max(12, min(34, preferences.cornerRadius))))
        }
        if state.hasPhysicalNotch {
            return NotchShape(topCornerRadius: NotchMetrics.closedTopRadius,
                              bottomCornerRadius: NotchMetrics.closedBottomRadius)
        }
        // No real cutout to hug on this display: a pill (half the bar's own height) reads as
        // an intentional floating bar instead of a shape flared for a notch that isn't there.
        let pill = state.closedSize.height / 2
        return NotchShape(topCornerRadius: pill, bottomCornerRadius: pill)
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
            .background(alignment: .top) {
                // Sits behind the clock/battery/text (which is drawn above, in the
                // Group), above the plain ink fill — so it blends the panel into the
                // physical camera cutout without washing out anything on top of it.
                // Holds solid black through most of the band before fading out over just
                // the last stretch, so the black reads as a deliberate slab, not a sliver.
                ZStack(alignment: .top) {
                    Color.dsInk0
                    // The album-art tint wash sits behind the black fade, not in front of
                    // it — otherwise a colorful album cover paints over the black band
                    // instead of black winning at the top no matter what's playing.
                    if state.expanded {
                        artworkTintWash
                        // The reference's wash lives only in the lower content, never
                        // touching the header strip or the physical cutout — the black
                        // fade below draws on top of it near the top edge, same as the
                        // reference keeps its mesh clear of the notch entirely.
                        DSWashLayer(baseColor: .clear, bold: true)
                    }
                    // Solid black for the band, meeting the wash along an undulating
                    // line instead of a ruler-straight horizontal seam. While collapsed
                    // the whole pill IS the band (same as before); while expanded it's
                    // capped to a header-height strip so it blends the physical cutout
                    // without also blacking out the wash across the rest of the much
                    // taller expanded panel.
                    //
                    // blur() softens every edge of the shape, not just the wavy bottom
                    // one — left unguarded, that also fades the flush top edge into a
                    // faint black-to-transparent gradient right where the panel meets
                    // the real menu bar, showing a sliver of wash color instead of solid
                    // bezel-black. Extending the rect blurPad above the visible frame
                    // and shifting it back down by the same amount pushes that top-edge
                    // softening above the panel's own clip region, so only the wavy
                    // bottom edge's blur ever renders.
                    let bandHeight = state.expanded ? min(70, state.currentSize.height) : state.currentSize.height
                    let blurPad: CGFloat = state.expanded ? 20 : 0
                    WavyEdgeRect(amplitude: state.expanded ? 6 : 0, wavelength: 90)
                        .fill(Color.black)
                        .frame(height: bandHeight + blurPad)
                        .offset(y: -blurPad)
                        .blur(radius: state.expanded ? 14 : 0)
                    // Collapsed pill has no room for the wash to read, but still gets a
                    // touch of grain so it's not the one bare surface in the suite.
                    if !state.expanded { DSGrainOverlay(opacity: 0.06) }
                }
            }
            // A physical notch must stay seamless bezel-black with no rim; the virtual bar on
            // notch-less displays has no cutout to blend into, so a hairline gives it definition
            // instead of reading as an unstyled black rectangle.
            .overlay {
                if !state.hasPhysicalNotch {
                    shape.stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
            }
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
            // A camera that keeps running after you've looked away and moved on is exactly
            // the surprise this kind of feature should never spring.
            .onChange(of: state.expanded) { _, expanded in
                if !expanded { mirror.stop() }
            }
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
            } else if state.peeking {
                sneakPeek
            } else {
                virtualCollapsedContent
            }
        }.contentShape(Rectangle()).onTapGesture(perform: onToggle)
    }
    /// The non-notch bar's at-rest content. "Now Playing" degrades to the clock when nothing
    /// is playing rather than a dead placeholder — that dead state was the single biggest
    /// reason this read as useless on displays with no physical cutout.
    @ViewBuilder
    private var virtualCollapsedContent: some View {
        switch preferences.collapsedContent {
        case .nowPlaying:
            if let item = media.item {
                HStack(spacing: 8) {
                    Image(systemName: item.playing ? "waveform" : "pause.fill").foregroundStyle(Color.dsAccent)
                    Text(item.title).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75)).lineLimit(1)
                    Spacer()
                }.padding(.horizontal, 12)
            } else {
                clockRow
            }
        case .clock:
            clockRow
        case .accent:
            HStack { Spacer(); Capsule().fill(Color.dsAccent.opacity(0.8))
                .frame(width: 28, height: 2); Spacer() }
        case .minimal:
            Color.clear
        }
    }
    private var clockRow: some View {
        TimelineView(.everyMinute) { context in
            HStack {
                Spacer()
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.85))
                Spacer()
            }
        }
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
    /// Clock, stats, and battery share the leading side of the strip the cutout occupies; the
    /// trailing side holds the app-shortcut/settings buttons so the calendar wing below never
    /// has to route around them.
    private var headerStrip: some View {
        HStack(spacing: 0) {
            Group {
                // The first readout leads the row so its left edge lines up with the
                // media wing's artwork below (both sit at the same leading padding).
                HStack(spacing: 12) {
                    ForEach(preferences.glanceItems) { glanceReadout($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: state.physicalNotchWidth)
            Group {
                HStack(spacing: 8) {
                    if preferences.showMirrorButton { mirrorButton }
                    ForEach(Self.appShortcuts) { info in
                        headerBarButton(symbol: info.symbolName, help: "Open \(info.displayName)") {
                            onOpenModule(info.id)
                        }
                    }
                    headerBarButton(symbol: "gearshape", help: "Open FreeKit Tools", action: onOpenTools)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: state.hasPhysicalNotch ? state.physicalNotchHeight : 22)
    }
    @ViewBuilder
    private func glanceReadout(_ item: BoringNotchGlanceItem) -> some View {
        switch item {
        case .time:
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        case .cpu: statReadout(symbol: "cpu", fraction: stats.cpuUsage)
        case .memory: statReadout(symbol: "memorychip", fraction: stats.memoryFraction)
        case .battery: batteryReadout
        }
    }
    private var batteryReadout: some View {
        HStack(spacing: 4) {
            Image(systemName: battery.charging ? "battery.100.bolt" : batterySymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(batteryTint)
                // Breathes while actually drawing wall power; a plugged-in laptop
                // that's already full has nothing live to announce.
                .dsLivePulse(battery.charging && battery.percent < 100)
            Text("\(battery.percent)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(batteryTint)
        }
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
    /// Accent while charging (the notch's one "live" color); a warm warning once it's
    /// actually low and not being topped up, so a glance catches it before it dies mid-call.
    private var batteryTint: Color {
        if battery.charging { return Color.dsAccent }
        if battery.percent <= 15 { return .orange }
        return Color.white.opacity(0.7)
    }
    /// One glyph + percent in exactly the battery readout's voice (same sizes, same order,
    /// monospaced digits so the value doesn't jitter as it updates every 2s).
    private func statReadout(symbol: String, fraction: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.75))
        }
    }
    private var expandedContent: some View {
        Group {
            if state.mirroring {
                mirrorModeContent.transition(.dsCrossfade)
            } else {
                wingsContent.transition(.dsCrossfade)
            }
        }
        .animation(DS.animCrossfade, value: state.mirroring)
    }
    /// Mirror mode: just the cutout strip and the camera preview beneath it — the panel
    /// itself has already shrunk to hug the feed, so nothing else fits (or should).
    private var mirrorModeContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: state.hasPhysicalNotch ? state.physicalNotchHeight : 22)
            mirrorContent
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 10)
        }
    }
    private var wingsContent: some View {
        VStack(spacing: 0) {
            // The physical cutout owns this strip; clock/stats/battery on the left and the
            // app-shortcut buttons on the right fill the space beside it, inset to the same
            // edges as the wings so the clock's left aligns with the media artwork.
            headerStrip
                .padding(.horizontal, NotchMetrics.openTopRadius + 16)
            // Symmetric spacers center the wings row (media + calendar) in
            // whatever room is left below the header, instead of the row
            // hugging the top with dead space beneath it whenever the
            // calendar wing is taller than the media wing's fixed content.
            Spacer(minLength: 4)
            HStack(alignment: .center, spacing: 18) {
                if preferences.mediaWingLeading {
                    // Each wing's content hugs whichever edge faces away from the divider, so
                    // swapping which side a wing sits on must also swap its own alignment —
                    // otherwise both wings cluster against the center divider instead of the
                    // shape's outer margins.
                    if preferences.showMedia { wing(mediaWing, leading: true) }
                    if preferences.showMedia, preferences.showCalendar { wingDivider }
                    if preferences.showCalendar { wing(calendarWing, leading: false) }
                } else {
                    if preferences.showCalendar { wing(calendarWing, leading: true) }
                    if preferences.showMedia, preferences.showCalendar { wingDivider }
                    if preferences.showMedia { wing(mediaWing, leading: false) }
                }
            }
            // Clear the shape's straight edges (openTopRadius inboard) plus a wider side margin so
            // the wings aren't cramped against the flared shoulders.
            .padding(.horizontal, NotchMetrics.openTopRadius + 16)
            Spacer(minLength: 10)
        }
    }
    private func headerBarButton(symbol: String, help: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 19, height: 16)
        }
        .buttonStyle(.plain)
        .help(help)
    }
    private func wing<V: View>(_ content: V, leading: Bool) -> some View {
        content.frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
    }
    private var wingDivider: some View {
        Rectangle().fill(Color.white.opacity(0.06))
            .frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 2)
    }
    private var mirrorButton: some View {
        Button {
            mirror.isRunning ? mirror.stop() : mirror.start()
        } label: {
            Image(systemName: mirror.isRunning ? "video.fill" : "video")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(mirror.isRunning ? Color.dsAccent : Color.white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help(mirror.isRunning ? "Close Mirror" : "Open Mirror")
    }
    /// Fills the wing area with a live front-camera preview, or a permission nudge if
    /// camera access was denied — swapped in for both wings while the mirror is open.
    private var mirrorContent: some View {
        Group {
            if mirror.authorizationDenied {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 18)).foregroundStyle(Color.white.opacity(0.4))
                    Text("Camera access is off")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.7))
                    Button("Open Settings") { Permissions.openCameraSettings() }
                        .buttonStyle(GhostButtonStyle())
                }
            } else {
                CameraPreviewView(session: mirror.session)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    /// A faint wash of the current artwork's dominant color behind the whole expanded card —
    /// only while media is showing and real album art loaded, so an empty/calendar-only notch
    /// stays neutral black.
    private var artworkTintWash: some View {
        Group {
            if preferences.showMedia, let tint = media.artworkTint {
                LinearGradient(colors: [Color(nsColor: tint).opacity(0.30), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
            }
        }
        .animation(DS.animCrossfade, value: media.artworkTint)
    }
    /// Buttons inside the wings (transport, day picker) still win their own hits; the tap
    /// gesture only catches clicks on the wing's passive content.
    private func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Log.error("notch: no app installed for bundle id \(bundleID)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    private func openCalendarApp() { openApp(bundleID: "com.apple.iCal") }
    private func openMusicApp() {
        if preferences.mediaSource == .appleMusic {
            openApp(bundleID: "com.apple.Music")
        } else if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil {
            openApp(bundleID: "com.spotify.client")
        } else {
            openApp(bundleID: "com.apple.Music")
        }
    }
    private var mediaWing: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                artworkView(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.item?.title ?? "Nothing Playing").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white).lineLimit(1)
                    Text(media.item?.artist ?? "Play something, anywhere").font(.system(size: 12, weight: .medium))
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
        .contentShape(Rectangle())
        .onTapGesture(perform: openMusicApp)
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
                // Real artwork otherwise gives no live cue of its own; a small badge reads as
                // "this is playing right now" without competing with the art itself.
                .overlay(alignment: .bottomTrailing) {
                    if media.item?.playing == true {
                        MiniEqualizer(active: true)
                            .scaleEffect(0.55)
                            .padding(3)
                            .background(Color.black.opacity(0.5), in: Circle())
                            .padding(2)
                    }
                }
        } else {
            Group {
                if media.item?.playing == true {
                    MiniEqualizer(active: true)
                } else {
                    Image(systemName: media.item?.source == .spotify
                          ? "dot.radiowaves.left.and.right" : "music.note")
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(Color.dsAccent)
                }
            }
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
        Group {
            if preferences.calendarStyle == .boring {
                calendarBoringStyle
            } else {
                calendarNonBoringStyles
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openCalendarApp)
    }
    private var calendarNonBoringStyles: some View {
        VStack(alignment: .trailing, spacing: 7) {
            Text("UP NEXT")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(0.6)
                .foregroundStyle(Color.white.opacity(0.28))
            if calendar.upcomingEvents.isEmpty {
                Text(calendar.hasAccess ? "Nothing upcoming" : "Calendar access off")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.white.opacity(0.4))
            } else {
                switch preferences.calendarStyle {
                case .boring: EmptyView()
                case .list: calendarListStyle
                case .compact: calendarCompactStyle
                case .agenda: calendarAgendaStyle
                }
            }
        }
    }
    /// Upstream boring.notch's calendar, scaled to the wing: month/year block
    /// beside a small day picker, then colored-bar rows with start/end times.
    private var calendarBoringStyle: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(selectedCalendarDay.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text(selectedCalendarDay.formatted(.dateTime.year()))
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                calendarDayStrip
            }
            let events = calendar.events(on: selectedCalendarDay)
            if !calendar.hasAccess {
                Text("Calendar access off")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
            } else if events.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.55))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Foundation.Calendar.current.isDateInToday(selectedCalendarDay)
                             ? "No events today" : "No events")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Text("Enjoy your free time!")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }
                .padding(.top, 2)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(events) { event in
                            boringEventRow(event)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var calendarDayStrip: some View {
        HStack(spacing: 3) {
            ForEach(-1..<4, id: \.self) { offset in
                let cal = Foundation.Calendar.current
                let date = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())) ?? Date()
                let isSelected = cal.isDate(date, inSameDayAs: selectedCalendarDay)
                let isToday = cal.isDateInToday(date)
                Button {
                    selectedCalendarDay = date
                } label: {
                    VStack(spacing: 2) {
                        Text(date, format: .dateTime.weekday(.narrow))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
                        ZStack {
                            Circle()
                                .fill(isToday ? Color.dsAccent : Color.clear)
                                .frame(width: 15, height: 15)
                            // Selection reads through a thin ring instead of a filled block,
                            // keeping the wing free of background washes.
                            if isSelected, !isToday {
                                Circle()
                                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                                    .frame(width: 15, height: 15)
                            }
                            Text(date, format: .dateTime.day())
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(isSelected || isToday ? Color.white : Color.white.opacity(0.55))
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 3)
                }
                .buttonStyle(.plain)
            }
        }
    }
    private func boringEventRow(_ event: BoringCalendarItem) -> some View {
        HStack(alignment: .center, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(nsColor: event.color))
                .frame(width: 3, height: 20)
            Text(event.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(event.startDate, format: .dateTime.hour().minute())
                    .foregroundStyle(Color.white)
                Text(event.endDate, format: .dateTime.hour().minute())
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
    }
    /// Original two-line-per-event layout: title, then time + calendar name, with a colored
    /// bar on the trailing edge keyed to the source calendar.
    private var calendarListStyle: some View {
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
    /// One line per event (dot + title + time) so more of the day fits without scrolling —
    /// trades the calendar-name detail for count, the way NotchNook's timeline reads.
    private var calendarCompactStyle: some View {
        ForEach(Array(calendar.upcomingEvents.prefix(4))) { event in
            HStack(spacing: 6) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                Text(event.startDate, format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.4))
                Circle().fill(Color(nsColor: event.color)).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    /// Leads with a large "in Xm/Xh" readout for the very next event — foregrounds urgency
    /// over a flat list, the way Notchable's agenda glance reads — then a thin tail of what's
    /// after it.
    private var calendarAgendaStyle: some View {
        let events = Array(calendar.upcomingEvents.prefix(3))
        return VStack(alignment: .trailing, spacing: 6) {
            if let next = events.first {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(next.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.relativeTime(from: context.date, to: next.startDate))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(nsColor: next.color))
                    }
                }
                ForEach(events.dropFirst()) { event in
                    HStack(spacing: 5) {
                        Text(event.title).lineLimit(1)
                            .font(.system(size: 10, weight: .medium))
                        Text(event.startDate, format: .dateTime.hour().minute())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(Color.white.opacity(0.4))
                }
            }
        }
    }
    private static func relativeTime(from now: Date, to start: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 0 { return "Now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60, remainder = minutes % 60
        return remainder == 0 ? "in \(hours)h" : "in \(hours)h \(remainder)m"
    }
}

/// Small pulsing bar trio standing in for a live audio visualizer, shown in place of the
/// static note glyph when something is actually playing and no real artwork loaded.
private struct MiniEqualizer: View {
    let active: Bool
    @State private var tall = false
    private static let heights: [(low: CGFloat, high: CGFloat)] = [(5, 13), (4, 9), (6, 12)]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(Color.dsAccent)
                    .frame(width: 3, height: tall ? Self.heights[i].high : Self.heights[i].low)
            }
        }
        .frame(width: 17, height: 14, alignment: .bottom)
        .animation(DS.animPulse(), value: tall)
        .onAppear { tall = active }
        .onChange(of: active) { _, now in tall = now }
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
                Text(preferences.mediaSource == .automatic
                     ? "Automatic prefers Spotify or Apple Music when either is open, then falls back to whatever else is playing system-wide (Safari, Podcasts, VLC, anything)."
                     : "Locked to \(preferences.mediaSource.rawValue) \u{2014} other apps' audio won't show here even if it's what's actually playing.")
                    .font(.system(size: 10)).foregroundStyle(Color.dsFaint)
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
                HStack(spacing: 8) { ForEach(BoringNotchCalendarStyle.allCases) { style in
                    DSChip(title: style.rawValue, selected: preferences.calendarStyle == style) {
                        preferences.calendarStyle = style
                    }
                }}
                Text(calendarStyleCaption)
                    .font(.system(size: 10)).foregroundStyle(Color.dsFaint)
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
                if preferences.showMedia && preferences.showCalendar {
                    DSToggleRow(title: "Media on the left", isOn: $preferences.mediaWingLeading)
                }
            }
            DSSettingsCard(title: "Menu bar strip") {
                Text("Two readouts sit left of the notch \u{2014} pick which two.")
                    .font(.system(size: 11)).foregroundStyle(Color.dsFaint)
                HStack(spacing: 8) { ForEach(BoringNotchGlanceItem.allCases) { item in
                    DSChip(title: item.rawValue, selected: preferences.glanceItems.contains(item)) {
                        toggleGlanceItem(item)
                    }
                }}
            }
            DSSettingsCard(title: "Mirror") {
                DSToggleRow(
                    title: "Show mirror button",
                    caption: "A camera icon that shrinks the notch to a quick front-camera preview \u{2014} handy before a call. Click anywhere else to dismiss it. Asks for Camera access the first time, and the camera never runs unless the mirror is open.",
                    isOn: $preferences.showMirrorButton)
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
                if hasPhysicalNotch {
                    DSToggleRow(title: "Show accent indicator", caption: "A small dot below the camera cutout at rest.",
                               isOn: $preferences.showAccent)
                }
            }
            if !hasPhysicalNotch {
                DSSettingsCard(title: "At rest") {
                    Text("What the bar shows when it's collapsed and nothing else is happening.")
                        .font(.system(size: 11)).foregroundStyle(Color.dsFaint)
                    HStack(spacing: 8) { ForEach(BoringNotchCollapsedContent.allCases) { style in
                        DSChip(title: style.rawValue, selected: preferences.collapsedContent == style) {
                            preferences.collapsedContent = style
                        }
                    }}
                }
            }
        }
    }
    /// Picking a third readout bumps the oldest so the strip always holds exactly two;
    /// deselecting stops at one so the strip never goes fully blank.
    private func toggleGlanceItem(_ item: BoringNotchGlanceItem) {
        var items = preferences.glanceItems
        if let index = items.firstIndex(of: item) {
            guard items.count > 1 else { return }
            items.remove(at: index)
        } else {
            items.append(item)
            if items.count > 2 { items.removeFirst() }
        }
        preferences.glanceItems = items
    }
    private var calendarStyleCaption: String {
        switch preferences.calendarStyle {
        case .boring: return "Month, a small day picker, and each event's start and end times."
        case .list: return "Title, time, and calendar name for the next two events."
        case .compact: return "One line per event so more of the day fits at a glance."
        case .agenda: return "Leads with a countdown to the very next event."
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String = "pt") -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.dsPaper)
                .frame(width: 112, alignment: .leading)
            DSSlider(value: value, range: range)
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
                HStack(spacing: 7) {
                    Text("12:19")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Image(systemName: "battery.75").font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text("85%").font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                NotchShape(topCornerRadius: 4, bottomCornerRadius: 7)
                    .fill(Color.dsInk0)
                    .frame(width: 132, height: 26)
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Image(systemName: "cursorarrow.click.2")
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Image(systemName: "gearshape")
                }
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.4))
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
