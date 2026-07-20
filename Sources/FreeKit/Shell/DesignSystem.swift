import AppKit
import SwiftUI

// Port of the ETok "Greenlight" design system (DESIGN.md), red variant:
// same ink neutrals, hairlines, radii, and mono label voice, with the volt-lime
// accent swapped for Apple's dark-mode system red so it reads native on macOS.
enum DS {
    static let ink0 = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 1)   // 0A0A0C
    static let ink1 = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.094, alpha: 1)   // 131318
    static let ink2 = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.141, alpha: 1)   // 1D1D24
    static let ink3 = NSColor(srgbRed: 0.149, green: 0.149, blue: 0.184, alpha: 1)   // 26262F
    static let line = NSColor(srgbRed: 0.165, green: 0.165, blue: 0.200, alpha: 1)   // 2A2A33
    static let paper = NSColor(srgbRed: 0.961, green: 0.961, blue: 0.941, alpha: 1)  // F5F5F0
    // Lifted from the reference's 8E8E99/55555F: those were picked against flat
    // ink, and the duotone wash sits light enough behind settings panes that
    // secondary text stopped carrying. These clear ~4.5:1 and ~3:1 on ink0.
    static let muted = NSColor(srgbRed: 0.678, green: 0.678, blue: 0.722, alpha: 1)  // ADADB8
    static let faint = NSColor(srgbRed: 0.518, green: 0.518, blue: 0.565, alpha: 1)  // 84848F
    static var accent: NSColor { AppearanceManager.shared.accentColor }
    static var accentDim: NSColor { AppearanceManager.shared.accentDimColor }
    static let glass = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.094, alpha: 0.85)
    // Hover overlay for transparent controls; ink3 is the hover/selected fill.
    static let controlHover = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05)

    static var radiusControl: CGFloat { AppearanceManager.shared.corners.controlRadius }
    static var radiusCard: CGFloat { AppearanceManager.shared.corners.cardRadius }
    static let radiusSheet: CGFloat = 28
    static let radiusKeycap: CGFloat = 10

    // One decelerate curve for all interface motion keeps the app calm;
    // only the pulse breathes symmetrically (ease-in-out, in HUD).
    static let durInstant: TimeInterval = 0.12
    static let durBase: TimeInterval = 0.20
    static let durSlow: TimeInterval = 0.32
    static let hudCrossfade: TimeInterval = 0.18

    // Greenlight's mono label voice: micro size, uppercase, wide tracking.
    static func microLabel(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .kern: 1.2,
                .foregroundColor: muted,
            ])
    }
}

// Greenlight ghost button: transparent fill, hairline border, paper text;
// hover lifts with the controlHover overlay, press fills ink3.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration)
    }

    private struct GhostButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(
                    configuration.isPressed
                        ? Color.dsInk3
                        : (hovering ? Color(nsColor: DS.controlHover) : Color.clear),
                    in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                        .strokeBorder(Color.dsLine, lineWidth: 1))
                .onHover { hovering = $0 }
                .animation(DS.animInstant, value: configuration.isPressed)
                .animation(DS.animInstant, value: hovering)
        }
    }
}

// Filled default-action button: paper fill, ink text. One per screen; accent
// red is the app's live-voice color, never decoration.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.dsInk0)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(
                Color.dsPaper.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            .animation(DS.animInstant, value: configuration.isPressed)
    }
}

// Minimal boolean toggle: 18x18. Red is reserved for live and for what is
// on, so the on-state fills accent (with the paper checkmark on top) instead
// of staying inside the ink neutrals.
struct DSCheckbox: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? Color.dsAccent : (hovering ? Color.dsInk3 : Color.dsInk2))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isOn ? Color.clear : Color.dsLine, lineWidth: 1)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.dsPaper)
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.animInstant, value: isOn)
    }
}

// Capsule chip for short one-of-many choices; hover fills ink3 at durInstant,
// selection is a solid accent fill with a soft glow (red is reserved for
// live and for what is on) rather than just an accent-bordered outline.
struct DSChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dsPaper)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    selected ? Color.dsAccent : (hovering ? Color.dsInk3 : Color.dsInk2),
                    in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Color.dsLine, lineWidth: 1))
                .shadow(color: selected ? Color.dsAccent.opacity(0.32) : .clear, radius: 10)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.animInstant, value: hovering)
        .animation(DS.animInstant, value: selected)
    }
}

// Capsule pill switch (iOS-style) for boolean rows inside settings panes —
// distinct from DSCheckbox's compact square, used where a full switch reads
// more naturally. Thumb slides with a critically-damped spring.
struct DSToggle: View {
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(DS.animToggle(reduceMotion: reduceMotion)) {
                isOn.toggle()
            }
        } label: {
            DSToggleBody(progress: isOn ? 1 : 0)
                .frame(width: 56, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// The reference's "gel" toggle: the track and the travelling thumb are drawn
// as one blurred layer that is then alpha-thresholded, so the thumb congeals
// out of the track (a metaball) instead of sliding over it. alphaThreshold
// recolors purely by coverage, which is why it merges where the earlier
// blur+contrast attempt only hazed — contrast shifts hue, not just alpha.
//
// Animatable (rather than a plain View) because a Canvas's draw closure is not
// interpolated by SwiftUI: without animatableData the goo would jump to its
// end state while the crisp thumb glided. Driving both off one 0...1 progress
// makes the blob, the track color, and the thumb travel as a single motion.
private struct DSToggleBody: View, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    // The reference hand-places these in its 56x30 box rather than deriving
    // them from the 50x16 track, so they are copied, not recomputed.
    private let knobOffX: CGFloat = 15
    private let knobOnX: CGFloat = 41
    private let knobY: CGFloat = 15

    private var clamped: CGFloat { min(max(progress, 0), 1) }
    private var knobX: CGFloat { knobOffX + (knobOnX - knobOffX) * clamped }
    private var trackColor: Color {
        Color(nsColor: DS.ink3.blended(withFraction: clamped, of: DS.accent) ?? DS.accent)
    }

    var body: some View {
        ZStack {
            Canvas { ctx, _ in
                ctx.addFilter(.alphaThreshold(min: 0.5, color: trackColor))
                // A little more blur = a longer, stretchier neck between track and
                // thumb as it travels, so the metaball reads as liquid, not solid.
                ctx.addFilter(.blur(radius: 5))
                ctx.drawLayer { layer in
                    let track = Path(
                        roundedRect: CGRect(x: 3, y: 7, width: 50, height: 16), cornerRadius: 8)
                    layer.fill(track, with: .color(.white))
                    let blob = Path(ellipseIn: CGRect(x: knobX - 14, y: 1, width: 28, height: 28))
                    layer.fill(blob, with: .color(.white))
                }
            }
            Circle()
                .fill(Color.dsPaper)
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .position(x: knobX, y: knobY)
        }
    }
}

// Small keycap-style card: an icon slot over a micro-label, dark fill with a
// drop shadow and an inset top highlight so it reads as a raised physical
// key. First use is HyperKey's Caps Lock graphic.
struct DSKeycap<Icon: View>: View {
    let label: String
    @ViewBuilder let icon: Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            icon
            Spacer(minLength: 0)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dsMuted)
        }
        .padding(11)
        .frame(width: 96, height: 60, alignment: .topLeading)
        .background(Color.dsInk2, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: 2)
    }
}

// Thick accent-fill track with a glowing paper thumb, replacing the native
// Slider's thin system track — this is the reference's most visible custom
// control, so it gets a fully custom drag surface rather than a `.tint()`.
struct DSSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var dragging = false

    // The reference's 24pt-tall design box: an 8pt track, a 14pt thumb, and the
    // thumb's travel inset by its own radius so it never overhangs either end.
    private static let boxHeight: CGFloat = 24
    private static let thumbDiameter: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            DSSliderBody(fraction: fraction, width: width, dragging: dragging)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            // Undo the thumb-radius inset the track uses, so the
                            // value under the cursor matches the thumb's position
                            // rather than drifting by up to half a thumb at the ends.
                            let travel = max(width - Self.thumbDiameter, 1)
                            let local = g.location.x - Self.thumbDiameter / 2
                            let f = min(max(local / travel, 0), 1)
                            value = range.lowerBound
                                + Double(f) * (range.upperBound - range.lowerBound)
                        }
                        .onEnded { _ in dragging = false })
        }
        .frame(height: Self.boxHeight)
        .animation(DS.animInstant, value: dragging)
        .dsNoWindowDrag()
    }

    private var fraction: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return CGFloat(min(max(f, 0), 1))
    }
}

// Same metaball technique as DSToggleBody: a blurred, alpha-thresholded Canvas
// layer draws a "neck" running back along the track plus a blob at the thumb, so
// the thumb reads as gel pulled out of the fill rather than a dot parked on it.
// The crisp paper thumb is drawn on top of the goo, not inside it.
private struct DSSliderBody: View {
    let fraction: CGFloat
    let width: CGFloat
    let dragging: Bool

    private let boxHeight: CGFloat = 24
    private let trackHeight: CGFloat = 8
    private let thumbDiameter: CGFloat = 14
    private var thumbRadius: CGFloat { thumbDiameter / 2 }

    // Thumb center, inset by its radius at both ends so it stays on the track.
    private var knob: CGFloat { thumbRadius + fraction * (width - thumbDiameter) }

    // Gel stays full across the interior and eases to nothing only in the last
    // ~10% at each end — so at 0%/100% just the clean circle shows (no neck stub
    // past the rounded cap, no blob clipping the edge) while everywhere else the
    // blob reads as a real gel ball. The old sin() taper peaked only at the exact
    // midpoint, leaving the metaball too small to see at any normal value.
    private var merge: CGFloat { min(min(fraction, 1 - fraction) / 0.1, 1) }
    private var neckWidth: CGFloat { 36 * merge }
    private var blobRadius: CGFloat { thumbRadius + 6 * merge }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.dsInk2).frame(height: trackHeight)
            // One cohesive accent fill (a whisper of accentDim→accent for depth,
            // not the old dark-red→accent two-tone) so the fill, the goo neck, and
            // the blob all read as the same orange piece the thumb sits in.
            Capsule()
                .fill(LinearGradient(
                    colors: [Color.dsAccentDim, Color.dsAccent],
                    startPoint: .leading, endPoint: .trailing))
                .frame(width: knob, height: trackHeight)
            Canvas { ctx, _ in
                ctx.addFilter(.alphaThreshold(min: 0.5, color: .dsAccent))
                ctx.addFilter(.blur(radius: 6))
                ctx.drawLayer { layer in
                    if neckWidth > 0.5 {
                        let neck = Path(
                            roundedRect: CGRect(
                                x: knob - neckWidth, y: boxHeight / 2 - 4,
                                width: neckWidth, height: 8),
                            cornerRadius: 4)
                        layer.fill(neck, with: .color(.white))
                    }
                    let blob = Path(
                        ellipseIn: CGRect(
                            x: knob - blobRadius, y: boxHeight / 2 - blobRadius,
                            width: blobRadius * 2, height: blobRadius * 2))
                    layer.fill(blob, with: .color(.white))
                }
            }
            .frame(height: boxHeight)
            .allowsHitTesting(false)
            Circle()
                .fill(Color.dsPaper)
                .frame(width: thumbDiameter, height: thumbDiameter)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .scaleEffect(dragging ? 1.12 : 1)
                .position(x: knob, y: boxHeight / 2)
        }
        .frame(height: boxHeight)
    }
}

// Quiet underline tab on a full-width hairline: selected = paper + 2px accent
// underline, unselected = muted lifting to paper on hover. No pill fill.
struct DSTabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.dsPaper : (hovering ? Color.dsPaper : Color.dsMuted))
                Rectangle()
                    .fill(selected
                        ? AnyShapeStyle(LinearGradient(
                            colors: [.clear, .dsAccent, .dsAccent, .clear],
                            startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.clear))
                    .frame(height: 2)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(DS.animBase, value: selected)
        .animation(DS.animInstant, value: hovering)
    }
}

// MARK: - Motion grammar
//
// Views say WHAT is happening (appearing, pressed, value changed, going live);
// this layer owns HOW it moves. One decelerate curve (easeOut) for every
// directional motion keeps the whole suite calm; the live pulse is the only
// symmetric ease-in-out. Reduce Motion is gated in exactly one place here, so
// every surface that consumes the grammar inherits it for free: directional
// animations collapse to nil (an instant state change), never a cut mid-flight.
extension DS {
    // AppKit-facing source of truth. SwiftUI modifiers below additionally read
    // @Environment(\.accessibilityReduceMotion) so they re-evaluate on a live toggle.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // nil under Reduce Motion -> withAnimation/.animation apply the change instantly.
    static func anim(_ duration: TimeInterval, reduceMotion rm: Bool = reduceMotion) -> Animation? {
        rm ? nil : .easeOut(duration: duration)
    }
    static var animInstant: Animation? { anim(durInstant) }   // press, hover
    static var animBase: Animation? { anim(durBase) }         // appear, select, value change
    static var animSlow: Animation? { anim(durSlow) }         // large panels
    static var animCrossfade: Animation? { anim(hudCrossfade) } // content swaps

    // Per-item appear delay, capped so a long list settles fast instead of
    // cascading forever.
    static let staggerStep: TimeInterval = 0.03
    static let staggerCap = 8
    static func animAppear(index: Int = 0, reduceMotion rm: Bool = reduceMotion) -> Animation? {
        rm ? nil : .easeOut(duration: durBase).delay(Double(min(max(index, 0), staggerCap)) * staggerStep)
    }

    // Expand/collapse of a large surface (the notch): a spring critically damped
    // (dampingFraction 1) so it reads physical but never overshoots or bounces.
    static func animExpand(reduceMotion rm: Bool = reduceMotion) -> Animation? {
        rm ? nil : .spring(response: 0.34, dampingFraction: 1)
    }

    // The gel toggle's thumb travel. Must be applied via withAnimation at the
    // mutation site, not .animation(_:value:) — an implicit value animation does
    // not propagate into DSToggleBody's Canvas animatableData, so the metaball
    // snaps to its end state instead of gliding. .smooth is a no-overshoot spring
    // so the thumb settles without the wobble a low-damping spring left on the goo.
    static func animToggle(reduceMotion rm: Bool = reduceMotion) -> Animation? {
        rm ? nil : .smooth(duration: 0.32)
    }

    // The one symmetric exception: a slow breathing pulse for a live/active dot.
    // Longer than durSlow on purpose (ambient idle), so it reads as breathing,
    // not a blink. Steady (no animation) under Reduce Motion.
    static func animPulse(reduceMotion rm: Bool = reduceMotion) -> Animation? {
        rm ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }
}

extension AnyTransition {
    // Cards/rows/panels enter with a fade and a few points of upward travel.
    // Under Reduce Motion the driving animation is nil, so the offset never
    // plays and the view simply appears.
    static var dsAppear: AnyTransition { .opacity.combined(with: .offset(y: 5)) }
    static var dsCrossfade: AnyTransition { .opacity }
}

// Press feedback shared with the existing button styles' idiom: a small scale
// dip, never a bounce. Adopt via .buttonStyle(.dsPress).
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(DS.anim(DS.durInstant, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
extension ButtonStyle where Self == PressableButtonStyle {
    static var dsPress: PressableButtonStyle { PressableButtonStyle() }
}

struct DSHoverHighlight: ViewModifier {
    var cornerRadius: CGFloat
    var fill: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(hovering ? fill : Color.clear,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(DS.anim(DS.durInstant, reduceMotion: reduceMotion), value: hovering)
    }
}

struct DSValueTransition<V: Equatable>: ViewModifier {
    let value: V
    let numeric: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .contentTransition(numeric ? .numericText() : .opacity)
            .animation(DS.anim(numeric ? DS.durBase : DS.hudCrossfade, reduceMotion: reduceMotion), value: value)
    }
}

// A live/active indicator that breathes while `active`, steady otherwise. Stops
// on inactive and on disappear so nothing animates offscreen.
struct DSLivePulse: ViewModifier {
    let active: Bool
    var dimTo: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(active && dim && !reduceMotion ? dimTo : 1)
            .onAppear { retune(active) }
            .onChange(of: active) { _, now in retune(now) }
            .onDisappear { dim = false }
    }
    private func retune(_ on: Bool) {
        guard on, !reduceMotion else { dim = false; return }  // plain assign cancels the repeatForever
        withAnimation(DS.animPulse()) { dim = true }
    }
}

extension View {
    func dsHoverHighlight(cornerRadius: CGFloat = DS.radiusControl, fill: Color = .dsInk3) -> some View {
        modifier(DSHoverHighlight(cornerRadius: cornerRadius, fill: fill))
    }
    // Numeric readouts (Stats counters, saved bytes, timers): native count roll.
    func dsValueTransition<V: Equatable>(_ value: V) -> some View {
        modifier(DSValueTransition(value: value, numeric: true))
    }
    // Arbitrary content swap (status text, hover-revealed rows): opacity crossfade.
    func dsContentCrossfade<V: Equatable>(_ value: V) -> some View {
        modifier(DSValueTransition(value: value, numeric: false))
    }
    func dsLivePulse(_ active: Bool, dimTo: Double = 0.45) -> some View {
        modifier(DSLivePulse(active: active, dimTo: dimTo))
    }
    // Every host window sets isMovableByWindowBackground so empty chrome can
    // drag it, but that races SwiftUI's own drag gesture on a Slider — AppKit
    // was winning and moving the window instead of the thumb. This drops an
    // invisible NSView behind the control that claims the hit-test spot and
    // refuses the window-drag, leaving the slider's own gesture to run.
    func dsNoWindowDrag() -> some View {
        background(DSWindowDragBlocker())
    }
    // Soft top/bottom fade for a scrolling pane instead of a hard clip, so
    // content reads as continuing past the edge rather than truncating
    // mid-line. Applied to the ScrollView itself (its viewport size is
    // stable) rather than its content (which grows with scroll length), so
    // the fade band stays a consistent proportion regardless of content.
    //
    // Each edge fades only while there is actually something hidden past it:
    // scrolled to the top, the top edge is crisp; scrolled to the bottom, the
    // bottom edge is. Fading an edge with nothing behind it just dims real
    // content (the first row of a pane) for no reason.
    func dsScrollEdgeFade() -> some View {
        modifier(DSScrollEdgeFade())
    }
}

private struct DSScrollEdgeFade: ViewModifier {
    private struct Edges: Equatable {
        var top = false
        var bottom = false
    }

    @State private var edges = Edges()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Edges.self) { geometry in
                let insets = geometry.contentInsets
                let offset = geometry.contentOffset.y + insets.top
                let scrollable = geometry.contentSize.height + insets.top + insets.bottom
                    - geometry.containerSize.height
                // Sub-point slack: a pane resting exactly at an edge can report a
                // fractional offset, which would otherwise flicker the fade on.
                guard scrollable > 1 else { return Edges() }
                return Edges(top: offset > 1, bottom: offset < scrollable - 1)
            } action: { _, newValue in
                edges = newValue
            }
            .mask(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom))
    }

    private var stops: [Gradient.Stop] {
        [
            .init(color: edges.top ? .clear : .black, location: 0),
            .init(color: .black, location: edges.top ? 0.04 : 0),
            .init(color: .black, location: edges.bottom ? 0.96 : 1),
            .init(color: edges.bottom ? .clear : .black, location: 1),
        ]
    }
}

// Historical belt-and-suspenders: with isMovableByWindowBackground now off on
// every FreeKit window (the real fix — AppKit's background drag split events
// with slider gestures and moved the window mid-drag, reproduced live), this
// blocker only matters if some future window turns background-drag back on.
private struct DSWindowDragBlocker: NSViewRepresentable {
    final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    func makeNSView(context: Context) -> BlockerView { BlockerView() }
    func updateNSView(_ nsView: BlockerView, context: Context) {}
}

// AppKit mirror of the grammar for NSView/NSPanel surfaces (HUD, module panels
// and toasts): same durations, same decelerate curve, same Reduce Motion gate,
// so AppKit and SwiftUI surfaces feel identical.
enum DSMotionAppKit {
    static var reduceMotion: Bool { DS.reduceMotion }

    static func run(duration: TimeInterval,
                    _ changes: @escaping (NSAnimationContext) -> Void,
                    completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0 : duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            changes(ctx)
        }, completionHandler: completion)
    }

    // Same fade + small vertical settle the HUD and app windows use, so every
    // floating panel in the suite reads as one motion language.
    static func fadeIn(_ panel: NSPanel, duration: TimeInterval = DS.hudCrossfade) {
        let target = panel.frame
        panel.alphaValue = 0
        if !reduceMotion { panel.setFrame(target.offsetBy(dx: 0, dy: -6), display: false) }
        panel.orderFrontRegardless()
        run(duration: duration) { _ in
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    static func fadeOut(_ panel: NSPanel, duration: TimeInterval = DS.hudCrossfade) {
        let target = panel.frame
        run(duration: duration, { _ in
            panel.animator().alphaValue = 0
            if !reduceMotion { panel.animator().setFrame(target.offsetBy(dx: 0, dy: -6), display: true) }
        }) { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            panel?.setFrame(target, display: false)
        }
    }

    // App windows/panels open with a quick fade + small upward settle and dismiss
    // with a fade, mirroring the HUD/panel treatment. Only a not-yet-visible window
    // animates, so re-showing an open one just brings it to front. Reduce Motion ->
    // plain show/dismiss.
    static func presentWindow(_ window: NSWindow) {
        guard !reduceMotion, !window.isVisible else {
            // Already on screen — but a dismiss fade-out may be mid-flight with
            // alpha driving to 0; snap it back to fully opaque so re-summoning
            // never leaves an invisible (or about-to-orderOut) window.
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            return
        }
        let target = window.frame
        window.alphaValue = 0
        window.setFrame(target.offsetBy(dx: 0, dy: -8), display: false)
        window.makeKeyAndOrderFront(nil)
        run(duration: DS.durBase) { _ in
            window.animator().alphaValue = 1
            window.animator().setFrame(target, display: true)
        }
    }

    static func dismissWindow(_ window: NSWindow, close: Bool) {
        let finish = { [weak window] in
            guard let window else { return }
            // A presentWindow may have run during our fade-out and reset alpha to
            // 1; in that case the user re-summoned the window, so don't order it
            // out from this now-stale completion.
            if window.alphaValue < 0.5 {
                if close { window.close() } else { window.orderOut(nil) }
            }
            window.alphaValue = 1
        }
        guard !reduceMotion, window.isVisible else { finish(); return }
        run(duration: DS.hudCrossfade, { _ in window.animator().alphaValue = 0 }, completion: finish)
    }

    // Grows/shrinks a window in place around its current center, clamped to
    // its screen — used when an in-window modal popup asks its host for more room.
    static func resizeWindow(_ window: NSWindow, toContentSize size: NSSize) {
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        resizeWindow(window, toFrame: centeredFrame(size: frame.size, around: window.frame, on: window.screen))
    }

    // For frame changes that accompany a SwiftUI expand transition (the
    // settings modal): timed and curved to land together with DS.animExpand's
    // 0.34s critically damped settle. The default resizeWindow's 0.20s easeOut
    // finished ahead of the card's spring, which read as a jump on open.
    static func resizeWindowMatchingExpand(_ window: NSWindow, toContentSize size: NSSize) {
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let target = centeredFrame(size: frame.size, around: window.frame, on: window.screen)
        guard !reduceMotion else { window.setFrame(target, display: true); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            // Strong decelerate, close to a dampingFraction-1 spring's tail.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
        }
    }

    static func resizeWindow(_ window: NSWindow, toFrame frame: NSRect) {
        guard !reduceMotion else { window.setFrame(frame, display: true); return }
        run(duration: DS.durBase) { _ in window.animator().setFrame(frame, display: true) }
    }

    private static func centeredFrame(size: NSSize, around previous: NSRect, on screen: NSScreen?) -> NSRect {
        var frame = NSRect(origin: .zero, size: size)
        frame.origin = NSPoint(x: previous.midX - size.width / 2, y: previous.midY - size.height / 2)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        return frame
    }
}

// Native equivalent of the reference design's SVG feTurbulence grain: a
// small pre-rendered noise tile, generated once and reused, tiled across the
// view and blended at low opacity so it reads as film grain over the wash
// gradient rather than redrawing noise every frame.
struct DSGrainOverlay: View {
    // The reference runs this layer at 0.26-0.5, but at native window scale
    // (not a shrunk marketing mockup) that read as too heavy in practice —
    // toned down while keeping it clearly visible rather than a hint.
    var opacity: Double = 0.16

    var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
            // Without this, the tile gets bilinear-smoothed at render scale,
            // which blurs sharp per-pixel randomness into soft blobby shapes
            // that read as a repeating printed pattern instead of grain —
            // nearest-neighbor sampling keeps every pixel a crisp, distinct
            // random value the way film grain actually looks.
            .interpolation(.none)
            .blendMode(.overlay)
            .opacity(opacity)
            .allowsHitTesting(false)
    }

    // Internal (not private) so custom Shapes that can't host a plain View
    // background — anything that overflows its own nominal frame, like the
    // settings card's corner blob — can fill themselves with this tile via
    // ImagePaint directly instead.
    static let tile: NSImage = {
        // Large enough that a full window's worth of grain doesn't visibly
        // repeat the same random draw — a small tile technically is random
        // per pixel, but human vision is very good at spotting the exact
        // same "random" pattern recurring every N points.
        let size = 256
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let data = bitmap.bitmapData
        else { return NSImage(size: NSSize(width: size, height: size)) }
        for i in 0..<(size * size) {
            let v = UInt8.random(in: 0...255)
            data[i * 4] = v
            data[i * 4 + 1] = v
            data[i * 4 + 2] = v
            data[i * 4 + 3] = 255
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(bitmap)
        return image
    }()
}

extension Color {
    static let dsInk0 = Color(nsColor: DS.ink0)
    static let dsInk1 = Color(nsColor: DS.ink1)
    static let dsInk2 = Color(nsColor: DS.ink2)
    static let dsInk3 = Color(nsColor: DS.ink3)
    static let dsLine = Color(nsColor: DS.line)
    static let dsPaper = Color(nsColor: DS.paper)
    static let dsMuted = Color(nsColor: DS.muted)
    static let dsFaint = Color(nsColor: DS.faint)
    static var dsAccent: Color { Color(nsColor: DS.accent) }
    static var dsAccentDim: Color { Color(nsColor: DS.accentDim) }
}
