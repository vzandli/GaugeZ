import AppKit

/// Which other edge a rail drag is reaching for. Dragging slides the rail along its own edge;
/// carrying the pointer out to a different edge of the same screen offers to move it there.
enum EdgeDropZone {
    /// How close to another edge the pointer must come before that edge is offered.
    static let reach: CGFloat = 72

    static func target(pointer: NSPoint, in frame: NSRect, current: EdgeSide) -> EdgeSide? {
        guard frame.insetBy(dx: -1, dy: -1).contains(pointer) else { return nil }
        let distances: [(EdgeSide, CGFloat)] = [
            (.left, pointer.x - frame.minX), (.right, frame.maxX - pointer.x),
            (.bottom, pointer.y - frame.minY), (.top, frame.maxY - pointer.y)
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= reach, nearest.0 != current else { return nil }
        return nearest.0
    }

    /// The strip drawn along `edge` while it is on offer.
    static func rect(for edge: EdgeSide, in frame: NSRect) -> NSRect {
        let depth: CGFloat = 10
        let length = (edge.isHorizontal ? frame.width : frame.height) * 0.4
        switch edge {
        case .left: return NSRect(x: frame.minX, y: frame.midY - length / 2, width: depth, height: length)
        case .right: return NSRect(x: frame.maxX - depth, y: frame.midY - length / 2, width: depth, height: length)
        case .top: return NSRect(x: frame.midX - length / 2, y: frame.maxY - depth, width: length, height: depth)
        case .bottom: return NSRect(x: frame.midX - length / 2, y: frame.minY, width: length, height: depth)
        }
    }
}

/// A click-through highlight marking the edge a drag would drop the rail on.
@MainActor
final class EdgeDropZoneOverlay {
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        window.contentView = view
        return window
    }()

    func show(_ edge: EdgeSide, on screen: NSScreen, tint: NSColor) {
        window.contentView?.layer?.backgroundColor = tint.withAlphaComponent(0.85).cgColor
        window.setFrame(EdgeDropZone.rect(for: edge, in: screen.visibleFrame), display: true)
        window.orderFrontRegardless()
    }

    func hide() { window.orderOut(nil) }
}
