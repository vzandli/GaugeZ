import SwiftUI

/// **The readings beside the Mac's own notch.** Joined to a MacBook's camera housing and at
/// rest, the rail shows nothing of its own; with this on, the housing widens into a black band
/// with a small ring either side of the camera, so the numbers are there without reaching for
/// the rail. Hovering the band opens the rail below it as before.
enum NotchEarsMetrics {
    static let ringPadding: CGFloat = 6
    static let ringSpacing: CGFloat = 7
    static let maximumPerSide = 3
    /// The band's outer corners curve into the screen's top edge by this much.
    static let flare: CGFloat = 7

    static func ringSize(notchHeight: CGFloat) -> CGFloat {
        max(18, (notchHeight - ringPadding * 2).rounded())
    }

    /// How many rings go on each side for `count` providers, within `available` width.
    static func perSide(count: Int, notch: HardwareNotch, available: CGFloat) -> Int {
        let ring = ringSize(notchHeight: notch.height)
        let room = (available - notch.width) / 2 - flare - ringPadding * 2
        let fit = max(0, Int((room + ringSpacing) / (ring + ringSpacing)))
        return min(maximumPerSide, fit, (count + 1) / 2)
    }

    static func earWidth(perSide: Int, notch: HardwareNotch) -> CGFloat {
        guard perSide > 0 else { return 0 }
        let ring = ringSize(notchHeight: notch.height)
        return CGFloat(perSide) * ring + CGFloat(perSide - 1) * ringSpacing + ringPadding * 2
    }

    /// The band's full width, flares included.
    static func width(perSide: Int, notch: HardwareNotch) -> CGFloat {
        guard perSide > 0 else { return notch.width }
        return notch.width + 2 * (earWidth(perSide: perSide, notch: notch) + flare)
    }
}

/// How everything around the notch moves, in one place so it moves like one thing: springs
/// just under bouncy, so the black settles like a liquid rather than arriving like a switch.
enum NotchMotion {
    /// The band growing out of the camera housing. Heavy enough to have mass, damped just
    /// under the point where it would stop dead: the small overshoot is the whole effect.
    static let unfold = Animation.spring(response: 0.62, dampingFraction: 0.72)
    /// Drawn back in. Quick, no delay, eased in, because a thing being taken into a mass
    /// accelerates as it goes, and it has to be inside the black while there is black left.
    static let merge = Animation.easeIn(duration: 0.2)
    /// **The glass drop.** Joined to the notch, the rail comes out of it as a drop of glass:
    /// it drips down from under the camera first, narrow, then spreads sideways into the rail.
    /// Going back it draws in from both sides into the drop, and only then is the drop taken
    /// back up into the notch. `drip` carries the depth, `spread` the width.
    static func drip(opening: Bool) -> Animation {
        opening ? .spring(response: 0.34, dampingFraction: 0.68)
                : .spring(response: 0.3, dampingFraction: 0.9).delay(0.16)
    }
    static func spread(opening: Bool) -> Animation {
        opening ? .spring(response: 0.52, dampingFraction: 0.7).delay(0.12)
                : .easeIn(duration: 0.18)
    }
    /// How narrow the drop is before it spreads: a little under the camera's width.
    static let dropWidthFraction: CGFloat = 0.42
    /// Rings arriving after the band has started to open, nearest the camera first.
    static func ring(_ distance: Int, after wait: Double = 0.08) -> Animation {
        .spring(response: 0.48, dampingFraction: 0.8).delay(wait + min(Double(distance) * 0.045, 0.18))
    }
    /// Closing the rail, the band waits for the drop to be back inside the notch first.
    static let returnDelay = 0.3
    /// A reading sweeping to its value, so a change reads as a measurement, not a glitch.
    static let reading = Animation.spring(response: 0.9, dampingFraction: 0.9)
}

struct NotchEarsView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let notch: HardwareNotch
    let perSide: Int
    /// Out beside the camera; false draws the band back into the housing.
    let extended: Bool
    let onHover: (Bool) -> Void

    /// Starts inside the housing on first show, so the band grows out of it rather than
    /// being there already.
    @State private var appeared = false

    var body: some View {
        let providers = Array(store.railProviders.prefix(perSide * 2))
        let left = Array(providers.prefix((providers.count + 1) / 2))
        let right = Array(providers.dropFirst(left.count))
        let ear = NotchEarsMetrics.earWidth(perSide: perSide, notch: notch)
        let out = extended && appeared
        let band = NotchBandShape(opening: out ? 1 : 0, notchWidth: notch.width,
                                  flare: NotchEarsMetrics.flare, cornerRadius: min(12, notch.height / 3))
        HStack(spacing: 0) {
            side(left, out: out, nearestLast: true).frame(width: ear)
            Color.clear.frame(width: notch.width)
            side(right, out: out, nearestLast: false).frame(width: ear)
        }
        .padding(.horizontal, NotchEarsMetrics.flare)
        .frame(width: NotchEarsMetrics.width(perSide: perSide, notch: notch), height: notch.height)
        // The rings are inside the black, so they come out of the housing with it.
        .mask(band)
        .background(band.fill(.black))
        .animation(reduceMotion ? nil : (out ? NotchMotion.unfold.delay(appeared ? NotchMotion.returnDelay : 0.05) : NotchMotion.merge), value: out)
        .contentShape(band)
        .allowsHitTesting(out)
        .onHover(perform: onHover)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!out)
        .onAppear { appeared = true }
    }

    private func side(_ providers: [ProviderID], out: Bool, nearestLast: Bool) -> some View {
        HStack(spacing: NotchEarsMetrics.ringSpacing) {
            ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                let distance = nearestLast ? providers.count - 1 - index : index
                NotchRing(snapshot: store.snapshot(for: provider),
                          size: NotchEarsMetrics.ringSize(notchHeight: notch.height),
                          shown: out)
                    .scaleEffect(out ? 1 : 0.35, anchor: nearestLast ? .trailing : .leading)
                    .opacity(out ? 1 : 0)
                    .animation(reduceMotion ? nil : (out ? NotchMotion.ring(distance, after: NotchMotion.returnDelay + 0.08) : NotchMotion.merge), value: out)
            }
        }
        .padding(.horizontal, NotchEarsMetrics.ringPadding)
        .frame(maxWidth: .infinity, alignment: nearestLast ? .trailing : .leading)
    }
}

/// One small ring: the remaining share of the headline window around the provider's mark.
private struct NotchRing: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: UsageSnapshot
    let size: CGFloat
    /// Out of the housing: the arc sweeps up to its value each time it comes out.
    let shown: Bool

    var body: some View {
        let lineWidth = max(2.5, size * 0.11)
        ZStack {
            Circle().stroke(snapshot.remainingPercent == 0 ? Color.red.opacity(0.7) : .white.opacity(0.14), lineWidth: lineWidth)
            if let remaining = snapshot.remainingPercent {
                Circle()
                    .trim(from: 0, to: shown ? CGFloat(remaining) / 100 : 0)
                    .stroke(store.quotaColor(remainingPercent: remaining),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            ProviderLogo(provider: snapshot.provider, size: size * 0.42)
                .foregroundStyle(.white.opacity(snapshot.remainingPercent == nil ? 0.4 : 0.92))
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : (shown ? NotchMotion.reading.delay(0.18) : .easeIn(duration: 0.15)), value: shown)
        .animation(reduceMotion ? nil : NotchMotion.reading, value: snapshot.remainingPercent)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: snapshot.remainingPercent.map {
            "\(snapshot.provider.displayName), \(PercentCopy.text($0))%"
        } ?? snapshot.provider.displayName))
    }
}

/// The widened notch: flat along the screen's top edge, rounded at the bottom, and curving
/// out into the top edge at both ends the way the camera housing itself does.
///
/// Animatable by how far it has come out of the housing, so a spring carries the outline
/// itself — width, flares and corners together — rather than a rect it is clipped to. At 0
/// it is no wider than the housing, black on black, and so not there at all.
struct NotchBandShape: Shape {
    var opening: CGFloat
    var notchWidth: CGFloat
    var flare: CGFloat
    var cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { opening }
        set { opening = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Past 1 on the spring's overshoot it keeps going a little, which is the settle.
        let reach = max(0, opening)
        let width = min(rect.width + flare, notchWidth + (rect.width - notchWidth) * reach)
        let body = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        let flare = self.flare * min(1, reach)
        let r = min(cornerRadius, body.height / 2, max(0, (body.width - 2 * flare) / 2))
        var path = Path()
        path.move(to: CGPoint(x: body.minX, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: body.minX + flare, y: body.minY + flare),
                          control: CGPoint(x: body.minX + flare, y: body.minY))
        path.addLine(to: CGPoint(x: body.minX + flare, y: body.maxY - r))
        path.addQuadCurve(to: CGPoint(x: body.minX + flare + r, y: body.maxY),
                          control: CGPoint(x: body.minX + flare, y: body.maxY))
        path.addLine(to: CGPoint(x: body.maxX - flare - r, y: body.maxY))
        path.addQuadCurve(to: CGPoint(x: body.maxX - flare, y: body.maxY - r),
                          control: CGPoint(x: body.maxX - flare, y: body.maxY))
        path.addLine(to: CGPoint(x: body.maxX - flare, y: body.minY + flare))
        path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY),
                          control: CGPoint(x: body.maxX - flare, y: body.minY))
        path.closeSubpath()
        return path
    }
}

/// The glass drop's outline, used as the rail's mask while it comes out of the notch: centred
/// under the camera, `spread` from a drop `dropWidth` wide to the rail's full width. Rounded
/// like a drop while narrow, and square by the time it is the rail, so the rail's own outline
/// takes over.
struct GlassDropMask: Shape {
    var spread: CGFloat
    var dropWidth: CGFloat

    var animatableData: CGFloat {
        get { spread }
        set { spread = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let reach = max(0, spread)
        let width = min(rect.width * 1.1, dropWidth + (rect.width - dropWidth) * reach)
        let body = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        // Round at the bottom like a hanging drop; flat along the top, where it hangs from.
        let radius = min(body.width / 2, body.height / 2) * max(0, 1 - min(1, reach) * 1.15)
        var path = Path()
        path.move(to: CGPoint(x: body.minX, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: body.maxX - radius, y: body.maxY), control: CGPoint(x: body.maxX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addQuadCurve(to: CGPoint(x: body.minX, y: body.maxY - radius), control: CGPoint(x: body.minX, y: body.maxY))
        path.closeSubpath()
        return path
    }
}
