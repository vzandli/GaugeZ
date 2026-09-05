import SwiftUI

/// Uses the same side-rail geometry rotated into horizontal placement.
enum HorizontalRailMetrics {
    static let depth = RailMetrics.expandedWidth
    static let cardGap = RailMetrics.attachmentGap + RailMetrics.pointerDepth
    static func width(providerCount: Int) -> CGFloat {
        max(RailMetrics.shapeHeight(providerCount: providerCount), RailMetrics.attachmentWidth + 24)
    }
}

struct HorizontalRailView: View {
    @EnvironmentObject private var store: UsageStore
    @ObservedObject var state: EdgePanelState
    let actions: EdgePanelActions

    var body: some View {
        GeometryReader { geometry in
            let top = store.edgeSide == .top
            let railLength = RailMetrics.shapeHeight(providerCount: store.visibleProviders.count)
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
                           height: min(state.attachmentHeight, max(0, geometry.size.height - HorizontalRailMetrics.depth - HorizontalRailMetrics.cardGap)))
                    .overlay(alignment: top ? .top : .bottom) {
                        if case .detail(let provider) = attachment {
                            CardPointerView(edge: .right)
                                .frame(width: RailMetrics.pointerDepth, height: 26)
                                .rotationEffect(.degrees(top ? -90 : 90))
                                .frame(width: 26, height: RailMetrics.pointerDepth)
                                .offset(x: pointerOffset(provider, railLength: railLength),
                                        y: top ? -RailMetrics.pointerDepth : RailMetrics.pointerDepth)
                        }
                    }
                    .padding(top ? .top : .bottom, HorizontalRailMetrics.depth + HorizontalRailMetrics.cardGap)
                    .onHover(perform: actions.attachmentHover)
                }

                // Rotating the actual side rail keeps its shoulders, end hook, settings orb,
                // drag grip, collapsed color chips, and materials identical across edges.
                // Only the meter contents and gear icon rotate back to stay readable.
                EdgeRailView(state: state, providers: store.visibleProviders, actions: actions,
                             renderingEdge: top ? .right : .left, contentRotation: 90)
                    .frame(width: HorizontalRailMetrics.depth, height: railLength,
                           alignment: top ? .trailing : .leading)
                    .rotationEffect(.degrees(-90))
                    .frame(width: railLength, height: HorizontalRailMetrics.depth)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: top ? .top : .bottom)
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

    private func pointerOffset(_ provider: ProviderID, railLength: CGFloat) -> CGFloat {
        let index = store.visibleProviders.firstIndex(of: provider) ?? 0
        let center = RailMetrics.rowCenterY(index: index)
        let maximum = (RailMetrics.attachmentWidth - RailMetrics.pointerDepth) / 2 - 28
        return max(-maximum, min(maximum, center - railLength / 2))
    }
}
