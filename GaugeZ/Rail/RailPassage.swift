import AppKit
import Combine
import QuartzCore
import SwiftUI

/// **The rail in the hand, drawn along the border and round its corners.**
///
/// A window cannot bend, so while a carried rail reaches round a corner it is drawn here, on
/// a click-through surface over the whole usable area, and the rail's own window waits out of
/// sight. The rail is split at each corner it crosses into one part per edge. Each part keeps
/// the rail's own rounded end where the rail ends, and its end in the corner closes up square
/// only as the part on the other side of the corner grows: reaching a corner, the rail rounds
/// off there and a bead comes out along the next edge, and the two run together as it grows.
/// The join is then closed — grown and shrunk back by the same radius — so the bend between
/// them fills in round, the way two drops run together.
///
/// Sliding the whole rail on past the corner instead pushed its rounded end off the screen,
/// and the rail looked sheared off flat against the corner.
enum RailPassageShape {
    /// The outline for a rail `length` long and `depth` deep with its middle at `middle` on
    /// the border, in the overlay's own top-left-origin space (the track's frame at 0,0).
    static func path(track: BorderTrack, middle: CGFloat, length: CGFloat, depth: CGFloat, scale: CGFloat) -> CGPath {
        let width = track.width
        let height = track.height
        let start = middle - length / 2
        let end = middle + length / 2
        // The rail's end, from the screen edge round to its inner side: what a part closing up
        // square gives up.
        let capLength = RailMetrics.shoulderHeight(scale: scale) + RailMetrics.bodyCornerRadius(scale: scale)

        // The corners the rail crosses, in border order, unwrapped to lie between its ends.
        var cuts: [CGFloat] = []
        for corner in BorderTrack.Corner.allCases {
            var p = track.position(of: corner)
            while p <= start { p += track.perimeter }
            while p - track.perimeter > start { p -= track.perimeter }
            if p < end { cuts.append(p) }
        }
        cuts.sort()
        let bounds = [start] + cuts + [end]
        let lengths = zip(bounds, bounds.dropFirst()).map { $1 - $0 }

        var pieces: [CGPath] = []
        for index in lengths.indices where lengths[index] > 0.5 {
            let from = bounds[index]
            let partLength = lengths[index]
            // A rail end keeps its round; a corner end squares up as the part beyond it grows.
            let startRound = index == 0 ? 1 : 1 - min(1, lengths[index - 1] / capLength)
            let endRound = index == lengths.count - 1 ? 1 : 1 - min(1, lengths[index + 1] / capLength)
            let edge = track.place(at: from + partLength / 2).edge
            let along = track.along(edge, of: from + partLength / 2) - partLength / 2
            var body = band(length: partLength, depth: depth, scale: scale, startRound: startRound, endRound: endRound)
            // Drawn for the right edge — the screen side at x = depth, running down, which is
            // clockwise — then laid along each edge's line clockwise, the screen side outward.
            var transform: CGAffineTransform
            switch edge {
            case .top: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: along, ty: depth)
            case .right: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: width - depth, ty: along)
            case .bottom: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: width - along, ty: height - depth)
            case .left: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: depth, ty: height - along)
            }
            if let piece = body.copy(using: &transform) { pieces.append(piece) }
            body = CGMutablePath()
        }
        // The bend: where two parts meet, the inside of the corner fills in on one wide curve,
        // as liquid would, rather than the few points a tight rounding gives. It needs both parts
        // at full depth that far out from the corner, so it grows in as they do.
        for index in cuts.indices {
            let before = lengths[index], after = lengths[index + 1]
            let squared = min(1, before / capLength, after / capLength)
            let radius = min(depth * 1.3, before - capLength - depth, after - capLength - depth) * squared
            guard radius > 1 else { continue }
            let corner = track.place(at: cuts[index] + 0.5).edge
            pieces.append(bend(at: corner, radius: radius, depth: depth, width: width, height: height))
        }
        guard var joined = pieces.first else { return CGMutablePath() }
        for piece in pieces.dropFirst() { joined = joined.union(piece) }

        if pieces.count > 1 {
            // A closing: grown by the radius, then shrunk back by it. Convex outlines come back
            // exactly as they were; the crease where two parts meet comes back filled round.
            let radius = (depth * 0.42).rounded()
            let grown = joined.union(joined.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
            joined = grown.subtracting(grown.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
        }
        return joined.intersection(CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil))
    }

    /// The material that fills the inside of a bend, for the corner the border turns onto
    /// `after`: bounded by the two parts' inner sides out to `radius` past the inner corner,
    /// and a curve between those two points that meets each side along its own line.
    static func bend(at after: EdgeSide, radius: CGFloat, depth: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
        // Inner corner, the way into it along the edge before, and out along the edge after.
        let (inner, into, out): (CGPoint, CGVector, CGVector)
        switch after {
        case .right: (inner, into, out) = (CGPoint(x: width - depth, y: depth), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1))
        case .bottom: (inner, into, out) = (CGPoint(x: width - depth, y: height - depth), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0))
        case .left: (inner, into, out) = (CGPoint(x: depth, y: height - depth), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1))
        case .top: (inner, into, out) = (CGPoint(x: depth, y: depth), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0))
        }
        let start = CGPoint(x: inner.x - into.dx * radius, y: inner.y - into.dy * radius)
        let end = CGPoint(x: inner.x + out.dx * radius, y: inner.y + out.dy * radius)
        let pull: CGFloat = 0.55
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: inner)
        path.addLine(to: end)
        path.addCurve(to: start,
                      control1: CGPoint(x: end.x + (inner.x - end.x) * pull, y: end.y + (inner.y - end.y) * pull),
                      control2: CGPoint(x: start.x + (inner.x - start.x) * pull, y: start.y + (inner.y - start.y) * pull))
        path.closeSubpath()
        return path
    }

    /// The rail's outline for the right edge — the same curves as `EdgeNotchOutline` — with
    /// each end's round scaled from 1, the rail's own end, to 0, cut square at full depth.
    static func band(length: CGFloat, depth: CGFloat, scale: CGFloat, startRound: CGFloat, endRound: CGFloat) -> CGMutablePath {
        let rect = CGRect(x: 0, y: 0, width: depth, height: length)
        let fullShoulder = RailMetrics.shoulderHeight(scale: scale)
        let fullCorner = min(RailMetrics.bodyCornerRadius(scale: scale), depth / 2)
        // Never more round than the part has room for.
        let room = length / 2
        let s1 = min(fullShoulder * startRound, room * fullShoulder / (fullShoulder + fullCorner))
        let r1 = min(fullCorner * startRound, room - s1)
        let s2 = min(fullShoulder * endRound, room * fullShoulder / (fullShoulder + fullCorner))
        let r2 = min(fullCorner * endRound, room - s2)
        let inner = rect.minX
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        let span1 = rect.maxX - (inner + r1)
        path.addCurve(to: CGPoint(x: inner + r1, y: rect.minY + s1),
                      control1: CGPoint(x: rect.maxX, y: rect.minY + s1 * 0.32),
                      control2: CGPoint(x: inner + r1 + span1 * 0.7, y: rect.minY + s1))
        if r1 > 0.01 {
            path.addArc(center: CGPoint(x: inner + r1, y: rect.minY + s1 + r1), radius: r1,
                        startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
        }
        path.addLine(to: CGPoint(x: inner, y: rect.maxY - s2 - r2))
        if r2 > 0.01 {
            path.addArc(center: CGPoint(x: inner + r2, y: rect.maxY - s2 - r2), radius: r2,
                        startAngle: .pi, endAngle: .pi / 2, clockwise: true)
        }
        let span2 = rect.maxX - (inner + r2)
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                      control1: CGPoint(x: inner + r2 + span2 * 0.7, y: rect.maxY - s2),
                      control2: CGPoint(x: rect.maxX, y: rect.maxY - s2 * 0.32))
        path.closeSubpath()
        return path
    }
}

/// What the passage surface draws: the outline, and what the rail carries in it.
@MainActor
final class RailPassageModel: ObservableObject {
    @Published var outline: CGPath?
    @Published var items: [PassageItem] = []
    @Published var scale: CGFloat = 1
}

/// Something the rail carries through the passage — a ring and its reading, or the settings
/// button — at its centre in the passage's own top-left-origin space.
struct PassageItem: Identifiable, Equatable {
    /// A provider's ring, or nil for the settings button.
    let provider: ProviderID?
    let centre: CGPoint
    /// Near a corner: the copy on one of its two edges, cut off at the corner's diagonal.
    let cut: Cut?

    struct Cut: Equatable {
        /// The screen's corner, in the passage's space.
        let corner: CGPoint
        /// Along the diagonal into the screen, and across it towards the side this copy keeps.
        let inward: CGVector
        let side: CGVector
        /// Tells the two copies of one item apart.
        let keepsBefore: Bool

        /// The side of the diagonal through the corner this copy keeps, as a region big
        /// enough to cover the screen.
        func region() -> Path {
            let far: CGFloat = 1e5
            let back = CGPoint(x: corner.x - inward.dx * far, y: corner.y - inward.dy * far)
            let ahead = CGPoint(x: corner.x + inward.dx * far, y: corner.y + inward.dy * far)
            var path = Path()
            path.move(to: back)
            path.addLine(to: ahead)
            path.addLine(to: CGPoint(x: ahead.x + side.dx * far, y: ahead.y + side.dy * far))
            path.addLine(to: CGPoint(x: back.x + side.dx * far, y: back.y + side.dy * far))
            path.closeSubpath()
            return path
        }
    }

    var id: String {
        let base = provider?.rawValue ?? "settings"
        guard let cut else { return base }
        return base + (cut.keepsBefore ? "-before" : "-after")
    }
}

private struct CGPathShape: Shape {
    let cgPath: CGPath
    func path(in rect: CGRect) -> Path { Path(cgPath) }
}

private struct RailPassageView: View {
    @EnvironmentObject private var store: UsageStore
    @ObservedObject var model: RailPassageModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let outline = model.outline {
                let shape = CGPathShape(cgPath: outline)
                if store.glassEnabled {
                    RailGlass.Frosted(shape: shape, glassOpacity: store.glassOpacity,
                                      tint: RailGlass.railTint(opacity: store.glassOpacity))
                    // Bent round a corner, clear glass over a dark window is all but invisible
                    // without an edge; a faint one keeps the shape there.
                    shape.stroke(.white.opacity(0.16), lineWidth: 1)
                } else {
                    shape.fill(Color(white: 0.02).opacity(0.98))
                    shape.stroke(.white.opacity(0.13), lineWidth: 1)
                }
                // The rail's own contents ride along the band and round the corner with it,
                // so what travels is the rail and not an empty smear of glass.
                ForEach(model.items) { item in
                    Group {
                        if let provider = item.provider {
                            PassageRing(snapshot: store.snapshot(for: provider), scale: model.scale)
                        } else {
                            PassageGear(scale: model.scale)
                        }
                    }
                    .position(item.centre)
                    .mask {
                        if let cut = item.cut { cut.region() } else { Rectangle() }
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}

/// A ring and its reading as the rail draws them, without anything to press.
private struct PassageRing: View {
    @EnvironmentObject private var store: UsageStore
    let snapshot: UsageSnapshot
    let scale: CGFloat

    var body: some View {
        let ringSize = RailMetrics.ringSize(scale: scale)
        let lineWidth = RailMetrics.ringLineWidth(scale: scale)
        VStack(spacing: RailMetrics.ringLabelGap(scale: scale)) {
            ZStack {
                Circle().stroke(snapshot.remainingPercent == 0 ? Color.red : .white.opacity(0.13), lineWidth: lineWidth)
                if let remaining = snapshot.remainingPercent {
                    Circle()
                        .trim(from: 0, to: CGFloat(remaining) / 100)
                        .stroke(store.quotaColor(remainingPercent: remaining),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                ProviderLogo(provider: snapshot.provider, size: max(12.0, (18.0 * scale).rounded()))
                    .foregroundStyle(.white.opacity(snapshot.remainingPercent == nil ? 0.4 : 0.95))
            }
            .frame(width: ringSize, height: ringSize)
            Text(snapshot.remainingPercent.map { "\(PercentCopy.text($0))%" } ?? "—")
                .font(.system(size: max(9.0, (13.0 * scale).rounded()), weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(snapshot.remainingPercent == nil ? 0.55 : 1))
                .frame(height: RailMetrics.labelHeight(scale: scale))
        }
        .fixedSize()
    }
}

private struct PassageGear: View {
    @EnvironmentObject private var store: UsageStore
    let scale: CGFloat

    var body: some View {
        let size = RailMetrics.gearButtonSize(scale: scale)
        Image(systemName: "gearshape")
            .font(.system(size: RailMetrics.gearIconSize(scale: scale), weight: .medium))
            .foregroundStyle(.white.opacity(0.68))
            .frame(width: size, height: size)
            .background {
                if store.glassEnabled {
                    RailGlass.Frosted(shape: Circle(), glassOpacity: store.glassOpacity,
                                      tint: RailGlass.railTint(opacity: store.glassOpacity))
                } else {
                    Circle().fill(Color(white: 0.04).opacity(0.97))
                }
            }
    }
}

/// The click-through surface over the usable area that a rail travelling round a corner is
/// drawn on. See `RailPassageShape`.
@MainActor
final class RailPassageOverlay {
    let model = RailPassageModel()
    private let store: UsageStore

    init(store: UsageStore) {
        self.store = store
    }

    private lazy var window: NSPanel = {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(RailPassageView(model: model).environmentObject(store)))
        host.sizingOptions = []
        window.contentView = host
        return window
    }()

    var isShown: Bool { window.isVisible && window.alphaValue > 0 }

    /// Lays the surface over `frame` (AppKit screen space) if it is not there already.
    func place(over frame: CGRect) {
        if window.frame != frame { window.setFrame(frame, display: false) }
    }

    func draw(_ outline: CGPath, items: [PassageItem], scale: CGFloat) {
        model.outline = outline
        if model.items != items { model.items = items }
        if model.scale != scale { model.scale = scale }
    }

    func fade(in visible: Bool, duration: TimeInterval) {
        if visible {
            if !window.isVisible {
                window.alphaValue = 0
                window.orderFrontRegardless()
            }
        } else if !window.isVisible {
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            window.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !visible, self.window.alphaValue == 0 else { return }
                self.window.orderOut(nil)
                self.model.outline = nil
            }
        })
    }

    func hide() {
        window.orderOut(nil)
        window.alphaValue = 0
        model.outline = nil
    }
}

/// Calls back once per frame of the display the view is on.
@MainActor
final class DisplayTicker: NSObject {
    private var link: CADisplayLink?
    private let onTick: (CFTimeInterval) -> Void
    private var last: CFTimeInterval?

    init(view: NSView, onTick: @escaping (CFTimeInterval) -> Void) {
        self.onTick = onTick
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last.map { now - $0 } ?? (1.0 / 120)
        last = now
        onTick(min(max(dt, 1.0 / 240), 1.0 / 30))
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}
