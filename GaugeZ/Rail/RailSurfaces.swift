import AppKit
import SwiftUI

// MARK: - Controls

extension View {
    /// The card buttons' style. Not the system `.glass` button style: inside this panel,
    /// which never becomes key, that style draws every button as an inactive control —
    /// dim label, faint fill — so an enabled button looked disabled until hovered.
    func glassControl(enabled: Bool = true, expands: Bool = true) -> some View {
        buttonStyle(RailButtonStyle(glass: enabled, expands: expands))
    }
}

/// A segmented control of the rail's own material, sized like `RailButtonStyle`: a glass
/// track the full width of the card, with the chosen segment as a lighter pill that slides
/// between choices. Not the system segmented picker: inside this panel, which never becomes
/// key, that control draws in its inactive grey — the same reason the card buttons have a
/// style of their own.
struct GlassSegmentedPicker<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    var glass = true

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered: Option?

    private static var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RailButtonStyle.cornerRadius, style: .continuous)
    }
    private static var segmentShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: RailButtonStyle.cornerRadius - 2, style: .continuous)
    }

    var body: some View {
        let systemGlass = RailGlass.systemGlassAvailable
            && RailGlass.rendersGlass(enabled: glass, reduceTransparency: reduceTransparency, contrast: contrast)

        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .frame(height: RailButtonStyle.height)
        .background {
            if systemGlass {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: Self.trackShape)
                }
                Self.trackShape.fill(.black.opacity(0.10))
            } else if glass && !reduceTransparency && contrast != .increased {
                RailGlass.Frosted(shape: Self.trackShape, glassOpacity: 0.5)
            } else {
                Self.trackShape.fill(.white.opacity(0.10))
                Self.trackShape.strokeBorder(.white.opacity(contrast == .increased ? 0.75 : 0.22), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: Option) -> some View {
        let selected = option == selection
        let isHovered = hovered == option && !selected
        return Text(label(option))
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(.white.opacity(selected ? 1 : 0.82))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    // The chosen segment: a lighter pill of the same shape, which is what
                    // the system's own glass segmented control does with its selection.
                    Self.segmentShape
                        .fill(.white.opacity(0.20))
                        .overlay(Self.segmentShape.strokeBorder(.white.opacity(0.22), lineWidth: 1))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else {
                    Self.segmentShape.fill(.white.opacity(isHovered ? 0.08 : 0))
                }
            }
            .contentShape(Self.segmentShape)
            .onTapGesture {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                    selection = option
                }
            }
            .onHover { inside in hovered = inside ? option : (hovered == option ? nil : hovered) }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The row of two buttons at the foot of a card: equal halves while both fit, and when the
/// second button's label is too long for half — "Open GitHub Copilot" — it takes the width
/// it needs and the first gives up the difference. A plain `HStack` cannot do this: it hands
/// the first flexible child half the row before the second has said what it needs.
struct ButtonPairRow: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = ideals.map(\.height).max() ?? 0
        let width = proposal.width
            ?? (ideals.map(\.width).reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0)))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let available = max(0, bounds.width - gaps)
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        var widths = Array(repeating: available / CGFloat(subviews.count), count: subviews.count)
        if subviews.count == 2, ideals[1] > widths[1] {
            // The second wants more than half: give it up to what the first can spare.
            widths[1] = min(ideals[1], max(available - ideals[0], available / 2))
            widths[0] = available - widths[1]
        }
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: widths[index], height: bounds.height))
            x += widths[index] + spacing
        }
    }
}

/// A bright arc that travels once around a shape's rim, with a soft glow under it: the
/// "light catches the edge" moment when the pointer arrives. Animatable on `progress`, so
/// one `withAnimation` from 0 to 1 moves the arc a full turn and fades it in and out at the
/// ends; at rest, either end, it draws nothing.
///
/// The arc is a trimmed stroke of the outline, so it moves by path length: the same speed
/// along a long side as around a corner. A rotating angular gradient does not — on a wide
/// pill it races along the sides and crawls round the ends.
struct RimSweep<S: InsettableShape>: ViewModifier, Animatable {
    let shape: S
    var lineWidth: CGFloat = 1.5
    var progress: Double = 0

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Full strength through the middle of the turn, fading over the first and last
        // fifth, so the arc neither pops in nor snaps out.
        let envelope = progress <= 0 || progress >= 1
            ? 0
            : min(1, 5 * min(progress, 1 - progress))
        content.overlay {
            ZStack {
                // Glow, tail, head: three runs of the same rim ending at the same point,
                // the shorter ones brighter, so the arc is brightest where it is going.
                run(length: 0.30, width: lineWidth + 3, opacity: 0.35).blur(radius: 5)
                run(length: 0.26, width: lineWidth, opacity: 0.30)
                run(length: 0.11, width: lineWidth, opacity: 0.95)
            }
            .opacity(envelope)
            .allowsHitTesting(false)
        }
    }

    /// A run of the outline `length` of the way round, ending at the head. Trimming cannot
    /// wrap past the path's start, so a run straddling it is drawn as two.
    private func run(length: Double, width: CGFloat, opacity: Double) -> some View {
        let outline = shape.inset(by: lineWidth / 2)
        let style = StrokeStyle(lineWidth: width, lineCap: .round)
        let head = progress
        let tail = head - length
        return ZStack {
            if tail < 0 {
                outline.trim(from: tail + 1, to: 1).stroke(.white.opacity(opacity), style: style)
                outline.trim(from: 0, to: head).stroke(.white.opacity(opacity), style: style)
            } else {
                outline.trim(from: tail, to: head).stroke(.white.opacity(opacity), style: style)
            }
        }
    }
}

/// A pill of the rail's own material with a full-strength label, so it reads as a live
/// control whether or not the panel is key. Glass on macOS 26 is interactive, so the system
/// answers the pointer and a press in the material itself; a hover lift of our own sits on
/// top of that, so the button always visibly answers the pointer — the system's response is
/// subtle, and absent below macOS 26. Only a button that is actually disabled is drawn dim.
struct RailButtonStyle: ButtonStyle {
    var glass = true
    /// Whether the button takes all the width it is offered. Two buttons on one row each
    /// expanding come out the same size, which is the only way a pair looks tidy.
    var expands = true

    static let height: CGFloat = 30
    static let cornerRadius: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        RailButtonBody(glass: glass, expands: expands, configuration: configuration)
    }
}

/// The style's body as a view of its own, because a hover state needs somewhere to live.
private struct RailButtonBody: View {
    let glass: Bool
    let expands: Bool
    let configuration: ButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    /// The rim sweep's progress: reset to 0 and run to 1 each time the pointer arrives.
    @State private var sweep: Double = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RailButtonStyle.cornerRadius, style: .continuous)
        let pressed = configuration.isPressed
        let systemGlass = RailGlass.systemGlassAvailable
            && RailGlass.rendersGlass(enabled: glass, reduceTransparency: reduceTransparency, contrast: contrast)
        // Resting, hovered, pressed: three steps of the same wash.
        let lift: Double = pressed ? 0.18 : (isHovered ? 0.10 : 0)

        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(height: RailButtonStyle.height)
            .background {
                if systemGlass {
                    if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.regular.interactive(), in: shape)
                    }
                    // A touch of body so the pill stands off the card on light wallpaper.
                    shape.fill(.white.opacity(0.07 + lift))
                } else if glass && !reduceTransparency && contrast != .increased {
                    RailGlass.Frosted(shape: shape, glassOpacity: 0.5)
                    shape.fill(.white.opacity(0.06 + lift))
                } else {
                    shape.fill(.white.opacity(0.14 + lift))
                    shape.strokeBorder(.white.opacity(contrast == .increased ? 0.75 : 0.22), lineWidth: 1)
                }
            }
            .overlay {
                // The rim catches the light a little more under the pointer.
                shape.strokeBorder(.white.opacity(isHovered && !pressed ? 0.22 : 0), lineWidth: 1)
            }
            .modifier(RimSweep(shape: shape, lineWidth: 1.5, progress: sweep))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(pressed ? 0.98 : 1)
            .onHover { inside in
                isHovered = inside && isEnabled
                if inside && isEnabled { runRimSweep() }
            }
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    private func runRimSweep() {
        guard !reduceMotion else { return }
        // Back to the start without animating there, then one turn.
        withTransaction(Transaction(animation: nil)) { sweep = 0 }
        withAnimation(.easeInOut(duration: 0.7)) { sweep = 1 }
    }
}

// MARK: - Liquid Glass surfaces

/// The rail, its cards and the gear are painted with the system's own Liquid Glass on
/// macOS 26: one `glassEffect` per silhouette, applied to a clear view, with nothing of ours
/// drawn over it. The system supplies the rim highlight, the refraction of what is behind
/// the panel, and the hover response of an interactive control; a sheen or a specular stroke
/// painted on top only dulls the material, and a wash under it overrides the Clear/Tinted
/// choice in the Mac's Appearance settings. No `GlassEffectContainer` either: inside this
/// borderless, transparent panel it allocated roughly 220 MB of backdrop buffers the moment
/// a card opened (measured with the attached settings card), while separate glass pieces
/// cost a few MB — and in an earlier attempt it rendered nothing at all.
///
/// Below macOS 26 there is no glass to hand the surface to, so the frosted imitation — a
/// behind-window blur under a tint, a top sheen and two edge strokes — stays as the fallback.
enum RailGlass {
    /// Whether this Mac has a Liquid Glass to hand the surfaces to at all.
    static var systemGlassAvailable: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }

    /// The transparency slider as the frosted fallback sees it: a black wash over the blur,
    /// from none at full transparency to a soft smoke at none.
    static func tint(for opacity: Double) -> Color {
        let clamped = max(0.0, min(1.0, opacity))
        return clamped > 0.01 ? Color.black.opacity(clamped * 0.24) : Color.clear
    }

    /// The same slider as the system glass sees it: a smoke tint on the material itself.
    /// Nil rather than a clear colour at full transparency, so the untinted surface is the
    /// plain system material and follows the Mac's own Clear/Tinted appearance choice.
    static func systemTint(for opacity: Double) -> Color? {
        let clamped = max(0.0, min(1.0, opacity))
        return clamped > 0.01 ? Color.black.opacity(clamped * 0.55) : nil
    }

    static func railTint(opacity: Double = 0.50) -> Color {
        tint(for: opacity)
    }

    static func cardTint(opacity: Double = 0.50) -> Color {
        tint(for: opacity)
    }

    static func panelTint(opacity: Double = 0.50) -> Color {
        tint(for: opacity)
    }

    static var railTint: Color { railTint() }
    static var cardTint: Color { cardTint() }
    static var panelTint: Color { panelTint() }

    /// Whether a surface is drawn as see-through glass at all. Reduce Transparency and
    /// Increase Contrast both ask for opaque chrome, and win over the material.
    static func rendersGlass(enabled: Bool, reduceTransparency: Bool, contrast: ColorSchemeContrast) -> Bool {
        enabled && !reduceTransparency && contrast != .increased
    }

    /// One piece of glass in the given shape: the system material on macOS 26, the frosted
    /// imitation before it, and an opaque outlined fill under Reduce Transparency or
    /// Increase Contrast.
    struct Frosted<S: Shape>: View {
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        let shape: S
        var glassOpacity: Double = 0.50
        var tint: Color? = nil
        /// Reacts to the pointer — for the one surface that is a button. Interactive glass
        /// has to see the pointer to respond to it, so this is the one case the surface is
        /// left hit-testable; it sits inside the button's label, which still takes the click.
        var interactive = false

        var body: some View {
            ZStack {
                if reduceTransparency || contrast == .increased {
                    shape.fill(Color(white: 0.04))
                    shape.stroke(.white.opacity(0.75), lineWidth: 1.5)
                } else if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(systemGlass, in: shape)
                } else {
                    legacyLayers
                }
            }
            .allowsHitTesting(interactive)
        }

        @available(macOS 26.0, *)
        private var systemGlass: Glass {
            let glass = Glass.regular.tint(RailGlass.systemTint(for: glassOpacity))
            return interactive ? glass.interactive() : glass
        }

        /// The pre-26 imitation: native blur, a tinted body, a top sheen, a specular edge and
        /// an outer hairline.
        @ViewBuilder
        private var legacyLayers: some View {
            let clampedOpacity = max(0.0, min(1.0, glassOpacity))
            let tintColor = tint ?? RailGlass.tint(for: clampedOpacity)

            BehindWindowBlur(material: .popover)
                .clipShape(shape)
                .opacity(max(0.22, 0.28 + clampedOpacity * 0.72))

            shape.fill(tintColor)

            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.12), location: 0.0),
                        .init(color: .white.opacity(0.03), location: 0.25),
                        .init(color: .clear, location: 0.60)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            shape
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.40), location: 0.0),
                            .init(color: .white.opacity(0.18), location: 0.45),
                            .init(color: .white.opacity(0.08), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )

            shape
                .stroke(Color.black.opacity(0.20), lineWidth: 0.5)
        }
    }

    /// Glass when enabled, otherwise the solid dark surface with a hairline edge.
    ///
    /// The drop shadow belongs to the imitation and the solid style only. System glass
    /// carries its own depth, and a shadow of ours under it shows through the material as a
    /// dark backing that the transparency slider can no longer clear.
    struct Surface<S: Shape>: ViewModifier {
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        let shape: S
        var glassOpacity: Double = 0.50
        var tint: Color? = nil
        let interactive: Bool
        let enabled: Bool
        var shadowed = true

        func body(content: Content) -> some View {
            let clampedOpacity = max(0.0, min(1.0, glassOpacity))
            let systemGlass = RailGlass.systemGlassAvailable
                && RailGlass.rendersGlass(enabled: enabled, reduceTransparency: reduceTransparency, contrast: contrast)
            content
                .background {
                    ZStack {
                        if shadowed && !systemGlass {
                            // Softened and scaled with opacity so it never darkens the
                            // interior of the more transparent settings.
                            shape.fill(.black.opacity(enabled ? clampedOpacity * 0.18 : 0.35))
                                .blur(radius: enabled ? 14 : 10)
                                .offset(y: 4)

                            shape.fill(.black.opacity(enabled ? clampedOpacity * 0.12 : 0.22))
                                .blur(radius: enabled ? 4 : 2)
                                .offset(y: 1)
                        }
                        if enabled {
                            Frosted(shape: shape, glassOpacity: glassOpacity, tint: tint, interactive: interactive)
                        } else {
                            shape.fill(Color(white: 0.04).opacity(0.97))
                            shape.stroke(.white.opacity(0.1), lineWidth: 1)
                        }
                    }
                }
        }
    }
}

struct BehindWindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // .popover provides rich wallpaper color transmission without forcing an opaque black mask
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
