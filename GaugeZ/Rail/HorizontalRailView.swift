import SwiftUI

/// Uses the same side-rail geometry rotated into horizontal placement.
enum HorizontalRailMetrics {
    static func depth(scale: CGFloat = 1.0) -> CGFloat { RailMetrics.expandedWidth(scale: scale) }
    static let cardGap = RailMetrics.attachmentGap + RailMetrics.pointerDepth
    static func width(providerCount: Int, scale: CGFloat = 1.0) -> CGFloat {
        max(RailMetrics.shapeHeight(providerCount: providerCount, scale: scale), RailMetrics.attachmentWidth + 24)
    }
}

struct HorizontalRailView: View {
    @EnvironmentObject private var store: UsageStore
    @ObservedObject var state: EdgePanelState
    let actions: EdgePanelActions

    var body: some View {
        GeometryReader { geometry in
            let top = store.edgeSide == .top
            let scale = CGFloat(store.railScale)
            let railLength = RailMetrics.shapeHeight(providerCount: store.railProviders.count, scale: scale)
            let depth = HorizontalRailMetrics.depth(scale: scale)
            let inset = top ? state.topInset : 0
            let available = geometry.size.height - inset
            ZStack(alignment: top ? .top : .bottom) {
                if state.isExpanded, let attachment = state.attachment {
                    ScrollView {
                        attachmentContent(attachment)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                                if state.attachmentHeight != height { state.attachmentHeight = height }
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: RailMetrics.attachmentWidth - RailMetrics.pointerDepth,
                           height: min(state.attachmentHeight, max(0, available - depth - HorizontalRailMetrics.cardGap)))
                    .overlay(alignment: top ? .top : .bottom) {
                        if case .detail(let provider) = attachment {
                            CardPointerView(edge: .right)
                                .frame(width: RailMetrics.pointerDepth, height: 26)
                                .rotationEffect(.degrees(top ? -90 : 90))
                                .frame(width: 26, height: RailMetrics.pointerDepth)
                                .offset(x: pointerOffset(provider, railLength: railLength, scale: scale),
                                        y: top ? -RailMetrics.pointerDepth : RailMetrics.pointerDepth)
                        }
                    }
                    .padding(top ? .top : .bottom, depth + HorizontalRailMetrics.cardGap)
                    .onHover(perform: actions.attachmentHover)
                }

                // Rotating the actual side rail keeps its shoulders, end hook, settings orb,
                // drag grip, collapsed color chips, and materials identical across edges.
                // Only the meter contents and gear icon rotate back to stay readable.
                EdgeRailView(state: state, providers: store.railProviders, actions: actions,
                             renderingEdge: top ? .right : .left, contentRotation: 90,
                             hidesCollapsedPill: top && state.joinedNotch != nil)
                    .frame(width: depth, height: railLength,
                           alignment: top ? .trailing : .leading)
                    .rotationEffect(.degrees(-90))
                    .frame(width: railLength, height: depth)
            }
            .frame(width: geometry.size.width, height: max(0, available), alignment: top ? .top : .bottom)
            // The inset band above holds the menu bar and the hardware notch; nothing is drawn in it.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            .overlay(alignment: .top) {
                // Joined to the notch, the notch itself is the hover target while the rail rests.
                if top, let notch = state.joinedNotch, !state.isExpanded {
                    Color.clear
                        .frame(width: notch.width, height: notch.height)
                        .contentShape(Rectangle())
                        .onHover(perform: actions.railHover)
                        .accessibilityHidden(true)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func attachmentContent(_ attachment: EdgeAttachment) -> some View {
        switch attachment {
        case .detail(let provider):
            UsageDetailCard(snapshot: store.snapshot(for: provider), openProvider: { store.open(provider) })
        case .settings:
            AttachedSettingsView(actions: actions)
        }
    }

    private func pointerOffset(_ provider: ProviderID, railLength: CGFloat, scale: CGFloat = 1.0) -> CGFloat {
        let index = store.railProviders.firstIndex(of: provider) ?? 0
        let center = RailMetrics.rowCenterY(index: index, scale: scale)
        let maximum = (RailMetrics.attachmentWidth - RailMetrics.pointerDepth) / 2 - 28
        return max(-maximum, min(maximum, center - railLength / 2))
    }
}
