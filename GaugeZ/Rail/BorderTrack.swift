import CoreGraphics

/// **The usable area's border as one line**, for a rail carried round it.
///
/// Measured clockwise from the top-left corner, in points: along the top edge, down the
/// right, back along the bottom and up the left. A rail's place on it is where its middle
/// is, so going round a corner is only that number running on past the corner's.
///
/// The frame is in AppKit's bottom-left-origin screen space, like `NSScreen.visibleFrame`.
struct BorderTrack: Equatable {
    let frame: CGRect

    var width: CGFloat { frame.width }
    var height: CGFloat { frame.height }
    var perimeter: CGFloat { 2 * (width + height) }

    enum Corner: CaseIterable, Equatable {
        case topRight, bottomRight, bottomLeft, topLeft
    }

    func position(of corner: Corner) -> CGFloat {
        switch corner {
        case .topLeft: 0
        case .topRight: width
        case .bottomRight: width + height
        case .bottomLeft: 2 * width + height
        }
    }

    /// The edges either side of a corner, in the order the border runs through it.
    static func edges(of corner: Corner) -> (before: EdgeSide, after: EdgeSide) {
        switch corner {
        case .topRight: (.top, .right)
        case .bottomRight: (.right, .bottom)
        case .bottomLeft: (.bottom, .left)
        case .topLeft: (.left, .top)
        }
    }

    /// Where an edge starts on the border, and how long it is.
    func start(of edge: EdgeSide) -> CGFloat {
        switch edge {
        case .top: 0
        case .right: width
        case .bottom: width + height
        case .left: 2 * width + height
        }
    }

    func length(of edge: EdgeSide) -> CGFloat {
        edge.isHorizontal ? width : height
    }

    func wrapped(_ position: CGFloat) -> CGFloat {
        guard perimeter > 0 else { return 0 }
        let r = position.truncatingRemainder(dividingBy: perimeter)
        return r < 0 ? r + perimeter : r
    }

    /// The shortest way round from `a` to `b`: negative is anticlockwise.
    func delta(from a: CGFloat, to b: CGFloat) -> CGFloat {
        var d = wrapped(b - a)
        if d > perimeter / 2 { d -= perimeter }
        return d
    }

    /// The edge a border position is on, and how far along it from the edge's own start.
    func place(at position: CGFloat) -> (edge: EdgeSide, along: CGFloat) {
        let s = wrapped(position)
        for edge in [EdgeSide.top, .right, .bottom, .left] where s < start(of: edge) + length(of: edge) {
            return (edge, s - start(of: edge))
        }
        return (.left, length(of: .left))
    }

    /// `position` measured from `edge`'s start, unwrapped towards that edge: a place round
    /// the corner past its end reads as more than its length, one before its start as less
    /// than zero. How a rail is laid along an edge's line when it reaches past it.
    func along(_ edge: EdgeSide, of position: CGFloat) -> CGFloat {
        let middle = start(of: edge) + length(of: edge) / 2
        return length(of: edge) / 2 + delta(from: middle, to: position)
    }

    /// A point projected onto `edge`, as a border position.
    func position(on edge: EdgeSide, of point: CGPoint) -> CGFloat {
        switch edge {
        case .top: return min(max(point.x - frame.minX, 0), width)
        case .right: return width + min(max(frame.maxY - point.y, 0), height)
        case .bottom: return width + height + min(max(frame.maxX - point.x, 0), width)
        case .left: return wrapped(2 * width + height + min(max(point.y - frame.minY, 0), height))
        }
    }

    /// The point a border position names, on the frame's outline.
    func point(at position: CGFloat) -> CGPoint {
        let (edge, along) = place(at: position)
        switch edge {
        case .top: return CGPoint(x: frame.minX + along, y: frame.maxY)
        case .right: return CGPoint(x: frame.maxX, y: frame.maxY - along)
        case .bottom: return CGPoint(x: frame.maxX - along, y: frame.minY)
        case .left: return CGPoint(x: frame.minX, y: frame.minY + along)
        }
    }

    /// How far a point is in from `edge`.
    func distance(to edge: EdgeSide, of point: CGPoint) -> CGFloat {
        switch edge {
        case .top: max(0, frame.maxY - point.y)
        case .bottom: max(0, point.y - frame.minY)
        case .left: max(0, point.x - frame.minX)
        case .right: max(0, frame.maxX - point.x)
        }
    }

    /// The edges a rail `length` long with its middle at `position` lies on, in border order.
    func edges(spannedBy position: CGFloat, length: CGFloat) -> [EdgeSide] {
        let from = position - length / 2
        return [EdgeSide.top, .right, .bottom, .left].filter { edge in
            let a = along(edge, of: from + length / 2)
            return a + length / 2 > 0 && a - length / 2 < self.length(of: edge)
        }
    }

    // MARK: - Reading the pointer

    /// **How the pointer's place on the border is read.** Along the edge it is nearest; or,
    /// within `cornerReach` of both edges at a corner, from both at once — how far it is from
    /// the edge before the corner, less how far from the edge after — so moving along either
    /// edge, or away from either, carries the rail round. Read from one edge only, a pointer
    /// stopped by the screen's corner moved nothing until it was well down the next edge.
    enum Reading: Equatable {
        case edge(EdgeSide)
        case corner(Corner)
    }

    static let cornerReach: CGFloat = 160

    /// How much nearer another edge the pointer has to be before its reading moves there, so
    /// a pointer near a corner does not send the rail back and forth between the two.
    static let edgeSwitchMargin: CGFloat = 40

    func nearestEdge(to point: CGPoint, current: EdgeSide?) -> EdgeSide {
        let edges: [EdgeSide] = [.top, .right, .bottom, .left]
        let nearest = edges.min { distance(to: $0, of: point) < distance(to: $1, of: point) } ?? .right
        guard let current, current != nearest else { return nearest }
        return distance(to: nearest, of: point) + Self.edgeSwitchMargin < distance(to: current, of: point) ? nearest : current
    }

    func reading(of point: CGPoint, nearest: EdgeSide) -> Reading {
        for corner in Corner.allCases {
            let (before, after) = Self.edges(of: corner)
            if distance(to: before, of: point) < Self.cornerReach, distance(to: after, of: point) < Self.cornerReach {
                return .corner(corner)
            }
        }
        return .edge(nearest)
    }

    func place(of point: CGPoint, by reading: Reading) -> CGFloat {
        switch reading {
        case .edge(let edge):
            return position(on: edge, of: point)
        case .corner(let corner):
            let (before, after) = Self.edges(of: corner)
            return wrapped(position(of: corner) + distance(to: before, of: point) - distance(to: after, of: point))
        }
    }
}

/// Where a rail's middle may rest on each edge, and how that maps to the saved position.
///
/// The saved position is the 0...1 slider value: bottom to top on the side edges, left to
/// right along the top and bottom, as `EdgePanelController.positionPanel` places the panel.
struct RailLanding: Equatable {
    let track: BorderTrack
    /// The rail's extent along a side edge: the notch and the settings button under it.
    let railLength: CGFloat
    /// The panel's width along the top and bottom edges, which the rail is centred in.
    let horizontalPanelWidth: CGFloat
    /// Kept clear at each end of a side edge.
    var sideMargin: CGFloat = 12

    /// The span the middle may take on `edge`, measured from the edge's start.
    func range(on edge: EdgeSide) -> ClosedRange<CGFloat> {
        let length = track.length(of: edge)
        let half = edge.isHorizontal ? min(horizontalPanelWidth, length) / 2 : railLength / 2 + sideMargin
        let low = min(half, length / 2)
        return low...max(low, length - low)
    }

    /// The saved position for a middle `along` an edge, clamped to where it may rest.
    func savedPosition(along: CGFloat, on edge: EdgeSide) -> Double {
        let range = range(on: edge)
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        let clamped = min(max(along, range.lowerBound), range.upperBound)
        let fraction = Double((clamped - range.lowerBound) / span)
        // The top edge runs left to right and the right edge top to bottom, as the border
        // does; the saved value runs left to right and bottom to top.
        switch edge {
        case .top, .left: return fraction
        case .right, .bottom: return 1 - fraction
        }
    }

    /// The border position of a rail resting at `saved` on `edge`.
    func position(saved: Double, on edge: EdgeSide) -> CGFloat {
        let range = range(on: edge)
        let fraction: CGFloat
        switch edge {
        case .top, .left: fraction = CGFloat(saved)
        case .right, .bottom: fraction = 1 - CGFloat(saved)
        }
        return track.start(of: edge) + range.lowerBound + (range.upperBound - range.lowerBound) * min(max(fraction, 0), 1)
    }

    /// Where a rail let go with its middle at `position` settles: on the edge holding its
    /// middle, slid back inside the range it may rest in.
    func landing(for position: CGFloat) -> (edge: EdgeSide, saved: Double, position: CGFloat) {
        let (edge, along) = track.place(at: position)
        let saved = savedPosition(along: along, on: edge)
        return (edge, saved, self.position(saved: saved, on: edge))
    }
}
