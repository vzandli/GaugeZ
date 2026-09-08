import AppKit
import Combine
import SwiftUI

// MARK: - Shared panel state

enum EdgeAttachment: Hashable {
    case detail(ProviderID)
    case settings
}

/// Observable state the hosting view renders from, so SwiftUI animates transitions instead of
/// the hierarchy being rebuilt on every change.
@MainActor
final class EdgePanelState: ObservableObject {
    @Published var isExpanded = false
    @Published var attachment: EdgeAttachment?
    @Published var hoveredProvider: ProviderID?
    @Published var attachmentHeight: CGFloat = 380
    /// Band at the top of a top-edge panel that holds nothing: the menu bar and, on a MacBook,
    /// the hardware notch the rail hangs beneath. Zero on every other placement.
    @Published var topInset: CGFloat = 0
    /// The display's own notch when the rail is joined to it; nil elsewhere.
    @Published var joinedNotch: HardwareNotch?
}

struct EdgePanelActions {
    var railHover: (Bool) -> Void = { _ in }
    var providerHover: (ProviderID?) -> Void = { _ in }
    var providerSelect: (ProviderID) -> Void = { _ in }
    var settingsToggle: () -> Void = {}
    var attachmentHover: (Bool) -> Void = { _ in }
    var gearZoneHover: (Bool) -> Void = { _ in }
    var dragStarted: () -> Void = {}
    var dragMoved: (CGFloat) -> Void = { _ in }
    var dragEnded: () -> Void = {}
}

/// Geometry shared by the views and the window controller. Points.
enum RailMetrics {
    static let baseExpandedWidth: CGFloat = 76
    static let baseRingSize: CGFloat = 44
    static let baseRingLineWidth: CGFloat = 4
    static let baseRingLabelGap: CGFloat = 5
    static let baseLabelHeight: CGFloat = 16
    static let baseRowSpacing: CGFloat = 14
    static let baseBodyTopInset: CGFloat = 16
    static let baseBodyBottomInset: CGFloat = 14
    static let baseShoulderHeight: CGFloat = 46
    static let baseFootHeight: CGFloat = 46
    static let baseBodyCornerRadius: CGFloat = 30

    static let collapsedWidth: CGFloat = 14
    static let resizeGripWidth: CGFloat = 8
    static let baseGearButtonSize: CGFloat = 42
    static let baseGearZoneHeight: CGFloat = 46
    static let baseGearOverlap: CGFloat = 10
    static let baseGearIconSize: CGFloat = 17
    static let attachmentWidth: CGFloat = 370
    static let attachmentGap: CGFloat = 8
    static let pointerDepth: CGFloat = 12

    static func expandedWidth(scale: CGFloat = 1.0) -> CGFloat { (baseExpandedWidth * scale).rounded() }
    static func ringSize(scale: CGFloat = 1.0) -> CGFloat { (baseRingSize * scale).rounded() }
    static func ringLineWidth(scale: CGFloat = 1.0) -> CGFloat { max(2.5, baseRingLineWidth * scale) }
    static func ringLabelGap(scale: CGFloat = 1.0) -> CGFloat { (baseRingLabelGap * scale).rounded() }
    static func labelHeight(scale: CGFloat = 1.0) -> CGFloat { (baseLabelHeight * scale).rounded() }
    static func rowSpacing(scale: CGFloat = 1.0) -> CGFloat { (baseRowSpacing * scale).rounded() }
    static func rowHeight(scale: CGFloat = 1.0) -> CGFloat {
        ringSize(scale: scale) + ringLabelGap(scale: scale) + labelHeight(scale: scale)
    }
    static func bodyTopInset(scale: CGFloat = 1.0) -> CGFloat { (baseBodyTopInset * scale).rounded() }
    static func bodyBottomInset(scale: CGFloat = 1.0) -> CGFloat { (baseBodyBottomInset * scale).rounded() }
    static func shoulderHeight(scale: CGFloat = 1.0) -> CGFloat { (baseShoulderHeight * scale).rounded() }
    static func footHeight(scale: CGFloat = 1.0) -> CGFloat { (baseFootHeight * scale).rounded() }
    static func bodyCornerRadius(scale: CGFloat = 1.0) -> CGFloat { (baseBodyCornerRadius * scale).rounded() }
    static func gearButtonSize(scale: CGFloat = 1.0) -> CGFloat { (baseGearButtonSize * scale).rounded() }
    static func gearZoneHeight(scale: CGFloat = 1.0) -> CGFloat { (baseGearZoneHeight * scale).rounded() }
    static func gearOverlap(scale: CGFloat = 1.0) -> CGFloat { (baseGearOverlap * scale).rounded() }
    static func gearIconSize(scale: CGFloat = 1.0) -> CGFloat { (baseGearIconSize * scale).rounded() }

    /// Widest the panel ever needs to be: rail plus an attachment.
    static func maximumPanelWidth(scale: CGFloat = 1.0) -> CGFloat {
        expandedWidth(scale: scale) + attachmentGap + attachmentWidth + pointerDepth
    }

    static func bodyHeight(providerCount: Int, scale: CGFloat = 1.0) -> CGFloat {
        let rows = CGFloat(max(providerCount, 1))
        return bodyTopInset(scale: scale) + rows * rowHeight(scale: scale) + (rows - 1) * rowSpacing(scale: scale) + bodyBottomInset(scale: scale)
    }

    static func notchHeight(providerCount: Int, scale: CGFloat = 1.0) -> CGFloat {
        shoulderHeight(scale: scale) + bodyHeight(providerCount: providerCount, scale: scale) + footHeight(scale: scale)
    }

    static func shapeHeight(providerCount: Int, scale: CGFloat = 1.0) -> CGFloat {
        notchHeight(providerCount: providerCount, scale: scale) + gearZoneHeight(scale: scale) - gearOverlap(scale: scale)
    }

    static func panelHeight(providerCount: Int, scale: CGFloat = 1.0) -> CGFloat {
        shapeHeight(providerCount: providerCount, scale: scale)
    }

    static func rowCenterY(index: Int, scale: CGFloat = 1.0) -> CGFloat {
        shoulderHeight(scale: scale) + bodyTopInset(scale: scale) + CGFloat(index) * (rowHeight(scale: scale) + rowSpacing(scale: scale)) + ringSize(scale: scale) / 2
    }
}

// MARK: - Root content

struct EdgePanelContentView: View {
    @EnvironmentObject private var store: UsageStore
    @ObservedObject var state: EdgePanelState
    let actions: EdgePanelActions

    var body: some View {
        if store.edgeSide.isHorizontal {
            HorizontalRailView(state: state, actions: actions)
        } else {
            verticalContent
        }
    }

    private var verticalContent: some View {
        let edge = store.edgeSide
        let providers = store.railProviders
        let scale = CGFloat(store.railScale)
        let shapeHeight = RailMetrics.shapeHeight(providerCount: providers.count, scale: scale)
        let panelHeight = RailMetrics.panelHeight(providerCount: providers.count, scale: scale)
        let maxPanelWidth = RailMetrics.maximumPanelWidth(scale: scale)
        let expandedWidth = RailMetrics.expandedWidth(scale: scale)

        let edgeAlignment: Alignment = edge == .right ? .topTrailing : .topLeading

        // The content lives in a container of constant maximum width anchored to the screen edge.
        // The window may be narrower than this container and simply clips it, so the rail's
        // position never changes when the window grows or shrinks, and nothing slides.
        let layers = ZStack(alignment: edgeAlignment) {
            Color.clear

            if state.isExpanded {
                AttachmentColumn(
                    attachment: state.attachment,
                    providers: providers,
                    shapeHeight: shapeHeight,
                    edge: edge,
                    scale: scale,
                    actions: actions
                )
                .padding(edge == .right ? .trailing : .leading, expandedWidth + RailMetrics.attachmentGap)
            }

            rail(providers: providers)
        }

        // Note: GlassEffectContainer is deliberately not used here; inside this borderless,
        // non-activating panel it rendered nothing at all.
        // The window is always exactly this size, so layout never depends on a resize.
        return layers
            .frame(width: maxPanelWidth, height: shapeHeight, alignment: edgeAlignment)
            .frame(width: maxPanelWidth, height: panelHeight, alignment: edge == .right ? .trailing : .leading)
            .environment(\.colorScheme, .dark)
    }

    private func rail(providers: [ProviderID]) -> some View {
        EdgeRailView(state: state, providers: providers, actions: actions)
    }
}

// MARK: - Drag handle

struct RailDragHandle: View {
    @EnvironmentObject private var store: UsageStore
    let actions: EdgePanelActions
    var scale: CGFloat = 1.0
    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        ZStack(alignment: .top) {
            NativeDragGrip(
                onDragStart: {
                    isDragging = true
                    actions.dragStarted()
                },
                onDragMove: { screenY in
                    actions.dragMoved(screenY)
                },
                onDragEnd: {
                    isDragging = false
                    actions.dragEnded()
                },
                onHover: { inside in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                        isHovered = inside
                    }
                }
            )

            // Visual indicator in the top shoulder: '-' when idle, bold '^ - v' when hovered/dragging
            VStack(spacing: 0) {
                Spacer().frame(height: 15)
                dragAffordance
            }
            .allowsHitTesting(false)
        }
        .frame(width: RailMetrics.expandedWidth(scale: scale), height: RailMetrics.shoulderHeight(scale: scale) + RailMetrics.bodyTopInset(scale: scale))
        .overlay(alignment: .bottom) {
            if store.railPageCount > 1 {
                Button {
                    store.railPage = (store.currentRailPage + 1) % store.railPageCount
                } label: {
                    Text("\(store.currentRailPage + 1)/\(store.railPageCount)")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .rotationEffect(.degrees(store.edgeSide.isHorizontal ? 90 : 0))
                .offset(y: 4)
                .help("Show the next page of accounts")
                .accessibilityLabel("Account page \(store.currentRailPage + 1) of \(store.railPageCount). Show next page")
            }
        }
        .contentShape(Rectangle())
        .help(store.edgeSide.isHorizontal ? "Drag horizontally to reposition GaugeZ" : "Drag vertically to reposition GaugeZ")
        .accessibilityLabel(store.edgeSide.isHorizontal ? "Drag handle to reposition GaugeZ horizontally" : "Drag handle to reposition GaugeZ vertically")
    }

    private var dragAffordance: some View {
        let active = isHovered || isDragging
        return ZStack {
            // Top chevron (slides up and expands on hover)
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(active ? (isDragging ? 1.0 : 0.90) : 0))
                .offset(y: active ? (isDragging ? -13.5 : -11.5) : 0)
                .scaleEffect(active ? 1.0 : 0.2)

            // Center bar (-) expands wider and thicker on hover
            Capsule()
                .fill(Color.white.opacity(active ? (isDragging ? 1.0 : 0.85) : 0.24))
                .frame(width: active ? 24 : 20, height: active ? 4 : 3.5)

            // Bottom chevron (slides down and expands on hover)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(active ? (isDragging ? 1.0 : 0.90) : 0))
                .offset(y: active ? (isDragging ? 13.5 : 11.5) : 0)
                .scaleEffect(active ? 1.0 : 0.2)
        }
        .shadow(color: .black.opacity(active ? 0.45 : 0), radius: 3, y: 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.70), value: active)
        .animation(.spring(response: 0.28, dampingFraction: 0.70), value: isDragging)
    }
}

private struct NativeDragGrip: NSViewRepresentable {
    let onDragStart: () -> Void
    let onDragMove: (CGFloat) -> Void
    let onDragEnd: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> DragGripNSView {
        let view = DragGripNSView()
        view.onDragStart = onDragStart
        view.onDragMove = onDragMove
        view.onDragEnd = onDragEnd
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: DragGripNSView, context: Context) {
        nsView.onDragStart = onDragStart
        nsView.onDragMove = onDragMove
        nsView.onDragEnd = onDragEnd
        nsView.onHover = onHover
    }
}

private final class DragGripNSView: NSView {
    var onDragStart: (() -> Void)?
    var onDragMove: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isDragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging {
            onHover?(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        NSCursor.closedHand.push()
        window?.invalidateCursorRects(for: self)
        onHover?(true)
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDragMove?(NSEvent.mouseLocation.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        window?.invalidateCursorRects(for: self)
        let isInside = bounds.contains(convert(event.locationInWindow, from: nil))
        onHover?(isInside)
        onDragEnd?()
    }
}

// MARK: - Notch resize handle

/// Drag grip along the notch's inner edge. Direction and cursor follow the real screen edge,
/// not the rendering edge, so the same view works inside the rotated horizontal rail.
struct RailResizeHandle: View {
    @EnvironmentObject private var store: UsageStore
    /// Scale band around 1.0 where the drag snaps to the default size.
    private static let snapBand = 0.05
    @State private var isHovered = false
    @State private var isResizing = false
    @State private var startScale: Double = 1.0
    @State private var initialLocation: NSPoint = .zero
    @State private var hasHapticSnapped = false

    var body: some View {
        let side = store.edgeSide
        return ZStack {
            NativeResizeGrip(
                edge: side,
                onResizeStart: { startPoint in
                    isResizing = true
                    startScale = store.railScale
                    initialLocation = startPoint
                    // Already at the default: don't tap on the first pixel of movement.
                    hasHapticSnapped = abs(startScale - 1.0) < Self.snapBand
                },
                onResizeMove: { currentPoint in
                    let baseWidth = RailMetrics.baseExpandedWidth
                    let delta: CGFloat
                    switch side {
                    case .right:
                        // Dragging left (decreasing X) increases size
                        delta = initialLocation.x - currentPoint.x
                    case .left:
                        // Dragging right (increasing X) increases size
                        delta = currentPoint.x - initialLocation.x
                    case .top:
                        // In macOS screen coords, 0 is bottom. Dragging down (decreasing Y) increases size
                        delta = initialLocation.y - currentPoint.y
                    case .bottom:
                        // Dragging up (increasing Y) increases size
                        delta = currentPoint.y - initialLocation.y
                    }
                    let scaleDelta = delta / baseWidth
                    var targetScale = startScale + Double(scaleDelta)

                    // Snap to 1.0 (default) with haptic feedback
                    if abs(targetScale - 1.0) < Self.snapBand {
                        targetScale = 1.0
                        if !hasHapticSnapped {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            hasHapticSnapped = true
                        }
                    } else {
                        hasHapticSnapped = false
                    }

                    store.railScale = max(0.70, min(1.40, targetScale))
                },
                onResizeEnd: {
                    isResizing = false
                },
                onDoubleClick: {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    store.resetRailScale()
                },
                onHover: { inside in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isHovered = inside
                    }
                }
            )

            // Faint visual affordance along the inner edge
            Capsule()
                .fill(Color.white.opacity(isResizing ? 0.38 : (isHovered ? 0.22 : 0.0)))
                .frame(width: 3, height: 32)
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isResizing)
                .allowsHitTesting(false)
        }
        .help("Drag to resize meter notch (Double-click to reset)")
    }
}

private struct NativeResizeGrip: NSViewRepresentable {
    let edge: EdgeSide
    let onResizeStart: (NSPoint) -> Void
    let onResizeMove: (NSPoint) -> Void
    let onResizeEnd: () -> Void
    let onDoubleClick: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> ResizeGripNSView {
        let view = ResizeGripNSView(edge: edge)
        view.onResizeStart = onResizeStart
        view.onResizeMove = onResizeMove
        view.onResizeEnd = onResizeEnd
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: ResizeGripNSView, context: Context) {
        nsView.edge = edge
        nsView.onResizeStart = onResizeStart
        nsView.onResizeMove = onResizeMove
        nsView.onResizeEnd = onResizeEnd
        nsView.onDoubleClick = onDoubleClick
        nsView.onHover = onHover
    }
}

private final class ResizeGripNSView: NSView {
    var edge: EdgeSide
    var onResizeStart: ((NSPoint) -> Void)?
    var onResizeMove: ((NSPoint) -> Void)?
    var onResizeEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isResizing = false
    private var cursorPushed = false

    init(edge: EdgeSide) {
        self.edge = edge
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// The window-edge resize cursor pointing at the edge being dragged; plain two-headed
    /// arrows before macOS 15. Pushed on hover rather than via cursor rects, which AppKit only
    /// honours in the key window and this non-activating panel never becomes key.
    private var resizeCursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch edge {
            case .right: position = .left
            case .left: position = .right
            case .top: position = .bottom
            case .bottom: position = .top
            }
            return .frameResize(position: position, directions: .all)
        }
        return edge.isHorizontal ? .resizeUpDown : .resizeLeftRight
    }

    private func showResizeCursor() {
        guard !cursorPushed else { return }
        resizeCursor.push()
        cursorPushed = true
    }

    private func restoreCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }

    override func mouseEntered(with event: NSEvent) {
        showResizeCursor()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isResizing else { return }
        restoreCursor()
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        isResizing = true
        showResizeCursor()
        onHover?(true)
        onResizeStart?(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing else { return }
        onResizeMove?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard isResizing else { return }
        isResizing = false
        let isInside = bounds.contains(convert(event.locationInWindow, from: nil))
        if !isInside { restoreCursor() }
        onHover?(isInside)
        onResizeEnd?()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { restoreCursor() }
    }
}

// MARK: - Rail

struct EdgeRailView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: EdgePanelState
    let providers: [ProviderID]
    let actions: EdgePanelActions
    var renderingEdge: EdgeSide? = nil
    var contentRotation: Double = 0
    /// Joined to a hardware notch the rail shows nothing at rest: the notch itself is the tab.
    var hidesCollapsedPill = false

    @State private var gearZoneHovered = false

    var body: some View {
        let edge = renderingEdge ?? store.edgeSide
        let expanded = state.isExpanded
        let scale = CGFloat(store.railScale)
        let expandedWidth = RailMetrics.expandedWidth(scale: scale)
        let width = expanded ? expandedWidth : RailMetrics.collapsedWidth
        let notchHeight = RailMetrics.notchHeight(providerCount: providers.count, scale: scale)

        ZStack(alignment: edge == .right ? .topTrailing : .topLeading) {
            Color.clear

            if expanded {
                railSurface(edge: edge, scale: scale)
                    .frame(width: expandedWidth, height: notchHeight)

                gearZone(edge: edge, scale: scale)
                    .offset(y: notchHeight - RailMetrics.gearOverlap(scale: scale) - (25 * scale).rounded())

                expandedContent(scale: scale)
                    .transition(.opacity.animation(.easeOut(duration: 0.12).delay(0.02)))

                // Resize grip on the inner notch edge, limited to the straight body section so it
                // doesn't sit over the shoulder curve or the drag handle. It's a native view, so
                // AppKit hit-tests it before any SwiftUI content regardless of z-order: keep it
                // narrow enough to stay inside the meter rows' side margin.
                RailResizeHandle()
                    .frame(width: RailMetrics.resizeGripWidth, height: RailMetrics.bodyHeight(providerCount: providers.count, scale: scale))
                    .padding(.top, RailMetrics.shoulderHeight(scale: scale))
                    .frame(maxWidth: .infinity, alignment: edge == .right ? .leading : .trailing)
            } else if !hidesCollapsedPill {
                collapsedPill(edge: edge)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .frame(width: width, alignment: edge == .right ? .trailing : .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .onHover(perform: actions.railHover)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            DebugLog.write("rail frame x=\(Int(frame.minX)) w=\(Int(frame.width)) y=\(Int(frame.minY)) h=\(Int(frame.height))")
        }
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.2, bounce: 0.1), value: expanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("GaugeZ usage rail")
    }

    private func expandedContent(scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            RailDragHandle(actions: actions, scale: scale)

            VStack(spacing: RailMetrics.rowSpacing(scale: scale)) {
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    ProviderMeterView(
                        snapshot: store.snapshot(for: provider),
                        revealIndex: index,
                        isHighlighted: state.hoveredProvider == provider || state.attachment == .detail(provider),
                        onHover: { inside in actions.providerHover(inside ? provider : nil) },
                        onSelect: { openApp in
                            if openApp { store.open(provider) } else { actions.providerSelect(provider) }
                        }
                    )
                    .rotationEffect(.degrees(contentRotation))
                }
            }

        }
        .frame(width: RailMetrics.expandedWidth(scale: scale))
    }

    private var gearHighlighted: Bool {
        gearZoneHovered || state.attachment == .settings
    }

    /// The body: Liquid Glass tinted near-black, or solid black with a hairline outline.
    @ViewBuilder
    private func railSurface(edge: EdgeSide, scale: CGFloat) -> some View {
        if store.glassEnabled {
            RailGlass.Frosted(
                shape: EdgeNotchShape(edge: edge, scale: scale),
                glassOpacity: store.glassOpacity,
                tint: RailGlass.railTint(opacity: store.glassOpacity)
            )
        } else {
            EdgeNotchShape(edge: edge, scale: scale)
                .fill(Color(white: 0.02).opacity(0.98))
            EdgeNotchOutline(edge: edge, scale: scale)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
    }

    /// Round settings button below the body, brightening while hovered or while settings are open.
    private func gearZone(edge: EdgeSide, scale: CGFloat) -> some View {
        let isOpen = state.attachment == .settings
        let buttonSize = RailMetrics.gearButtonSize(scale: scale)
        return Button(action: actions.settingsToggle) {
            ZStack {
                // Subtle glass specular ring when active/hovered
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(gearHighlighted ? 0.38 : 0.12),
                                Color.white.opacity(gearHighlighted ? 0.14 : 0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .frame(width: buttonSize, height: buttonSize)

                // Mechanical rotating gear icon
                Image(systemName: "gearshape")
                    .font(.system(size: RailMetrics.gearIconSize(scale: scale), weight: .medium))
                    .foregroundStyle(.white.opacity(gearHighlighted ? 1.0 : 0.68))
                    .rotationEffect(.degrees(contentRotation + (isOpen ? 90 : (gearZoneHovered ? 45 : 0))))
                    .scaleEffect(isOpen ? 1.15 : (gearZoneHovered ? 1.10 : 1.0))
                    .shadow(color: .white.opacity(isOpen ? 0.35 : (gearZoneHovered ? 0.20 : 0)), radius: 4)
                    .animation(.spring(response: 0.32, dampingFraction: 0.68), value: gearZoneHovered)
                    .animation(.spring(response: 0.35, dampingFraction: 0.70), value: isOpen)
            }
            .frame(width: buttonSize, height: buttonSize)
            // No shadow: the rail body it sits under has none, and the rail clips at its edges.
            .modifier(RailGlass.Surface(
                shape: Circle(),
                glassOpacity: store.glassOpacity,
                tint: RailGlass.railTint(opacity: store.glassOpacity),
                interactive: true,
                enabled: store.glassEnabled,
                shadowed: false
            ))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .frame(width: RailMetrics.expandedWidth(scale: scale), height: RailMetrics.gearZoneHeight(scale: scale), alignment: .top)
        .padding(.top, (3 * scale).rounded())
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.70)) {
                gearZoneHovered = inside
            }
            actions.gearZoneHover(inside)
        }
        .help("GaugeZ settings (Right-click for options)")
        .accessibilityLabel("Settings")
    }

    private func collapsedPill(edge: EdgeSide) -> some View {
        let dotTones = store.indicatorVariants
        let dotSize: CGFloat = 5
        let dotSpacing: CGFloat = 2
        let internalPadding: CGFloat = 2
        let totalHeight: CGFloat = CGFloat(dotTones.count) * dotSize + CGFloat(dotTones.count - 1) * dotSpacing + internalPadding * 2

        return VStack(spacing: dotSpacing) {
            ForEach(0..<dotTones.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(dotTones[index])
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .padding(internalPadding)
        .background(
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.13).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .padding(edge == .right ? .trailing : .leading, 2)
        .frame(maxWidth: .infinity, alignment: edge == .right ? .trailing : .leading)
        .padding(.top, (RailMetrics.shapeHeight(providerCount: providers.count, scale: CGFloat(store.railScale)) - totalHeight) / 2)
    }
}

// MARK: - Attachment column (detail card or settings), anchored to the hovered row

private struct AttachmentColumn: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let attachment: EdgeAttachment?
    let providers: [ProviderID]
    let shapeHeight: CGFloat
    let edge: EdgeSide
    var scale: CGFloat = 1.0
    let actions: EdgePanelActions

    @State private var contentHeight: CGFloat = 120

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let attachment {
                card(for: attachment)
                    // Identity includes the padding so an outgoing card keeps its own anchor
                    // while it fades, instead of jumping to the incoming card's position.
                    .id(attachment)
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(x: reduceMotion ? 0 : (edge == .right ? 8 : -8)))
                            .animation(.easeOut(duration: 0.15).delay(0.08)),
                        removal: .opacity.animation(.easeIn(duration: 0.08))
                    ))
            }
        }
        .frame(width: RailMetrics.attachmentWidth + RailMetrics.pointerDepth, height: shapeHeight, alignment: .top)
    }

    private func card(for attachment: EdgeAttachment) -> some View {
        let anchorY = anchorCenterY(for: attachment)
        let topPadding = max(0, min(anchorY - contentHeight / 2, shapeHeight - contentHeight))
        let pointerY = anchorY - topPadding

        return ZStack(alignment: edge == .right ? .topTrailing : .topLeading) {
            if case .detail = attachment {
                CardPointerView(edge: edge)
                    .frame(width: RailMetrics.pointerDepth, height: 26)
                    .offset(
                        x: edge == .right ? RailMetrics.pointerDepth : -RailMetrics.pointerDepth,
                        y: max(20, min(pointerY, contentHeight - 20)) - 13
                    )
            }

            ScrollView {
                content(for: attachment)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                        if contentHeight != newHeight { contentHeight = newHeight }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, shapeHeight))
            .onHover(perform: actions.attachmentHover)
        }
        .frame(width: RailMetrics.attachmentWidth, alignment: edge == .right ? .trailing : .leading)
        .padding(edge == .right ? .trailing : .leading, RailMetrics.pointerDepth)
        .padding(.top, topPadding)
    }

    @ViewBuilder
    private func content(for attachment: EdgeAttachment) -> some View {
        switch attachment {
        case .detail(let provider):
            UsageDetailCard(snapshot: store.snapshot(for: provider), openProvider: { store.open(provider) })
        case .settings:
            AttachedSettingsView(actions: actions)
        }
    }

    private func anchorCenterY(for attachment: EdgeAttachment) -> CGFloat {
        switch attachment {
        case .detail(let provider):
            let index = providers.firstIndex(of: provider) ?? 0
            return RailMetrics.rowCenterY(index: index, scale: scale)
        case .settings:
            return shapeHeight / 2
        }
    }
}

// MARK: - Shapes

/// The black edge body: a concave shoulder that flows out of the screen edge, a straight inner
/// side with rounded corners, and a smaller concave foot back into the edge. Drawn for the
/// right edge and mirrored for the left.
struct EdgeNotchShape: Shape {
    let edge: EdgeSide
    var scale: CGFloat = 1.0

    func path(in rect: CGRect) -> Path {
        var path = EdgeNotchOutline.outline(in: rect, scale: scale)
        path.closeSubpath()
        return edge == .left ? path.mirrored(in: rect) : path
    }
}

/// The visible outline of the body (everything except the screen-edge side), used for the
/// hairline border.
struct EdgeNotchOutline: Shape {
    let edge: EdgeSide
    var scale: CGFloat = 1.0

    func path(in rect: CGRect) -> Path {
        let path = Self.outline(in: rect, scale: scale)
        return edge == .left ? path.mirrored(in: rect) : path
    }

    static func outline(in rect: CGRect, scale: CGFloat = 1.0) -> Path {
        let shoulder = RailMetrics.shoulderHeight(scale: scale)
        let foot = RailMetrics.footHeight(scale: scale)
        let corner = min(RailMetrics.bodyCornerRadius(scale: scale), rect.width / 2)
        let bodyTop = rect.minY + shoulder
        let bodyBottom = rect.maxY - foot
        let inner = rect.minX

        // Long, symmetric handles keep the S-curves gentle so no curvature bunches at the joins.
        let span = rect.maxX - (inner + corner)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Concave shoulder: tangent to the screen edge, ending tangent to the body top.
        path.addCurve(
            to: CGPoint(x: inner + corner, y: bodyTop),
            control1: CGPoint(x: rect.maxX, y: rect.minY + shoulder * 0.68),
            control2: CGPoint(x: inner + corner + span * 0.7, y: bodyTop)
        )
        path.addArc(
            center: CGPoint(x: inner + corner, y: bodyTop + corner),
            radius: corner, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true
        )
        path.addLine(to: CGPoint(x: inner, y: bodyBottom - corner))
        path.addArc(
            center: CGPoint(x: inner + corner, y: bodyBottom - corner),
            radius: corner, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true
        )
        // Concave foot back into the edge: exact symmetric mirror of the shoulder curve.
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: bodyBottom + foot),
            control1: CGPoint(x: inner + corner + span * 0.7, y: bodyBottom),
            control2: CGPoint(x: rect.maxX, y: bodyBottom + foot * 0.68)
        )
        return path
    }
}

/// Brand mark rendered as a template image so it takes the surrounding foreground colour.
struct ProviderLogo: View {
    let provider: ProviderID
    let size: CGFloat

    var body: some View {
        (provider.usesSymbolLogo ? Image(systemName: provider.symbolName) : Image(provider.logoAssetName))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Triangle on the rail side of a detail card.
struct CardPointer: Shape {
    let edge: EdgeSide

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return edge == .left ? path.mirrored(in: rect) : path
    }
}

/// Outline of the pointer's two slanted legs (omitting the base touching the card).
struct CardPointerOutline: Shape {
    let edge: EdgeSide

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return edge == .left ? path.mirrored(in: rect) : path
    }
}

/// Caret view with Liquid Glass frosted blur or solid fill and matching hairline stroke.
struct CardPointerView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let edge: EdgeSide

    var body: some View {
        let shape = CardPointer(edge: edge)
        let outline = CardPointerOutline(edge: edge)

        ZStack {
            shape.fill(.black.opacity(store.glassEnabled ? store.glassOpacity * 0.18 : 0.35))
                .blur(radius: store.glassEnabled ? 6 : 8)
                .offset(y: 3)

            if store.glassEnabled && !reduceTransparency && contrast != .increased {
                let clampedOpacity = max(0.0, min(1.0, store.glassOpacity))
                BehindWindowBlur(material: .popover)
                    .clipShape(shape)
                    .opacity(max(0.22, 0.28 + clampedOpacity * 0.72))
                shape.fill(RailGlass.cardTint(opacity: store.glassOpacity))
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.12), location: 0.0),
                            .init(color: .white.opacity(0.03), location: 0.40),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: edge == .right ? .topLeading : .topTrailing,
                        endPoint: edge == .right ? .bottomTrailing : .bottomLeading
                    )
                )
                outline.stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.40), location: 0.0),
                            .init(color: .white.opacity(0.18), location: 0.40),
                            .init(color: .white.opacity(0.08), location: 1.0)
                        ],
                        startPoint: edge == .right ? .topLeading : .topTrailing,
                        endPoint: edge == .right ? .bottomTrailing : .bottomLeading
                    ),
                    lineWidth: 0.75
                )
            } else {
                shape.fill(Color(white: 0.04))
                outline.stroke(.white.opacity(contrast == .increased ? 0.75 : 0.1), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

private extension Path {
    func mirrored(in rect: CGRect) -> Path {
        applying(CGAffineTransform(translationX: rect.maxX + rect.minX, y: 0).scaledBy(x: -1, y: 1))
    }
}
