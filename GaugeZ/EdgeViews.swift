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
}

struct EdgePanelActions {
    var railHover: (Bool) -> Void = { _ in }
    var providerHover: (ProviderID?) -> Void = { _ in }
    var providerSelect: (ProviderID) -> Void = { _ in }
    var settingsToggle: () -> Void = {}
    var attachmentHover: (Bool) -> Void = { _ in }
    var gearZoneHover: (Bool) -> Void = { _ in }
}

/// Geometry shared by the views and the window controller. Points.
enum RailMetrics {
    static let expandedWidth: CGFloat = 76
    static let collapsedWidth: CGFloat = 14
    static let ringSize: CGFloat = 44
    static let ringLineWidth: CGFloat = 4
    static let ringLabelGap: CGFloat = 5
    static let labelHeight: CGFloat = 16
    static let rowSpacing: CGFloat = 14
    static let rowHeight: CGFloat = ringSize + ringLabelGap + labelHeight
    static let bodyTopInset: CGFloat = 16
    static let bodyBottomInset: CGFloat = 14
    static let shoulderHeight: CGFloat = 46
    static let footHeight: CGFloat = 46
    static let gearButtonSize: CGFloat = 42
    static let gearZoneHeight: CGFloat = 46
    static let gearOverlap: CGFloat = 10
    static let attachmentWidth: CGFloat = 370
    static let attachmentGap: CGFloat = 8
    static let pointerDepth: CGFloat = 12
    static let bodyCornerRadius: CGFloat = 30

    static var hookHeight: CGFloat {
        footHeight + gearZoneHeight - gearOverlap
    }

    /// Widest the panel ever needs to be: rail plus an attachment.
    static let maximumPanelWidth: CGFloat = expandedWidth + attachmentGap + attachmentWidth + pointerDepth

    static func bodyHeight(providerCount: Int) -> CGFloat {
        let rows = CGFloat(max(providerCount, 1))
        return bodyTopInset + rows * rowHeight + (rows - 1) * rowSpacing + bodyBottomInset
    }

    static func notchHeight(providerCount: Int) -> CGFloat {
        shoulderHeight + bodyHeight(providerCount: providerCount) + footHeight
    }

    static func shapeHeight(providerCount: Int) -> CGFloat {
        notchHeight(providerCount: providerCount) + gearZoneHeight - gearOverlap
    }

    /// Window height: exact match to shapeHeight.
    static func panelHeight(providerCount: Int) -> CGFloat {
        shapeHeight(providerCount: providerCount)
    }

    /// Vertical center of a provider row, measured from the top of the rail shape.
    static func rowCenterY(index: Int) -> CGFloat {
        shoulderHeight + bodyTopInset + CGFloat(index) * (rowHeight + rowSpacing) + ringSize / 2
    }
}

// MARK: - Root content

struct EdgePanelContentView: View {
    @EnvironmentObject private var store: UsageStore
    @ObservedObject var state: EdgePanelState
    let actions: EdgePanelActions

    var body: some View {
        let edge = store.edgeSide
        let providers = store.visibleProviders
        let shapeHeight = RailMetrics.shapeHeight(providerCount: providers.count)

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
                    actions: actions
                )
                .padding(edge == .right ? .trailing : .leading, RailMetrics.expandedWidth + RailMetrics.attachmentGap)
            }

            rail(providers: providers)
        }

        // Note: GlassEffectContainer is deliberately not used here; inside this borderless,
        // non-activating panel it rendered nothing at all.
        // The window is always exactly this size, so layout never depends on a resize.
        layers
            .frame(width: RailMetrics.maximumPanelWidth, height: shapeHeight, alignment: edgeAlignment)
            .frame(width: RailMetrics.maximumPanelWidth, height: RailMetrics.panelHeight(providerCount: providers.count), alignment: edge == .right ? .trailing : .leading)
            .environment(\.colorScheme, .dark)
    }

    private func rail(providers: [ProviderID]) -> some View {
        EdgeRailView(state: state, providers: providers, actions: actions)
    }
}

// MARK: - Rail

struct EdgeRailView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: EdgePanelState
    let providers: [ProviderID]
    let actions: EdgePanelActions

    @State private var gearZoneHovered = false

    var body: some View {
        let edge = store.edgeSide
        let expanded = state.isExpanded
        let width = expanded ? RailMetrics.expandedWidth : RailMetrics.collapsedWidth

        ZStack(alignment: edge == .right ? .topTrailing : .topLeading) {
            Color.clear

            if expanded {
                railSurface(edge: edge)
                    .frame(width: RailMetrics.expandedWidth, height: RailMetrics.notchHeight(providerCount: providers.count))

                gearZone(edge: edge)
                    .offset(y: RailMetrics.notchHeight(providerCount: providers.count) - RailMetrics.gearOverlap - 25)

                expandedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.12).delay(0.02)))
            } else {
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

    private var expandedContent: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: RailMetrics.shoulderHeight + RailMetrics.bodyTopInset)

            VStack(spacing: RailMetrics.rowSpacing) {
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
                }
            }

        }
        .frame(width: RailMetrics.expandedWidth)
    }

    private var gearHighlighted: Bool {
        gearZoneHovered || state.attachment == .settings
    }

    /// The body: Liquid Glass tinted near-black, or solid black with a hairline outline.
    @ViewBuilder
    private func railSurface(edge: EdgeSide) -> some View {
        if store.glassEnabled {
            RailGlass.Frosted(
                shape: EdgeNotchShape(edge: edge),
                glassOpacity: store.glassOpacity,
                tint: RailGlass.railTint(opacity: store.glassOpacity)
            )
        } else {
            EdgeNotchShape(edge: edge)
                .fill(Color(white: 0.02).opacity(0.98))
            EdgeNotchOutline(edge: edge)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
    }

    /// Round settings button below the body, brightening while hovered or while settings are open.
    private func gearZone(edge: EdgeSide) -> some View {
        Button(action: actions.settingsToggle) {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(gearHighlighted ? 1 : 0.7))
                .frame(width: RailMetrics.gearButtonSize, height: RailMetrics.gearButtonSize)
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
        .scaleEffect(gearHighlighted ? 1.06 : 1)
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
        .frame(width: RailMetrics.expandedWidth, height: RailMetrics.gearZoneHeight, alignment: .top)
        .padding(.top, 3)
        .contentShape(Rectangle())
        .onHover { inside in
            gearZoneHovered = inside
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
        .padding(.top, (RailMetrics.shapeHeight(providerCount: providers.count) - totalHeight) / 2)
    }
}

private struct ProviderMeterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: UsageSnapshot
    let revealIndex: Int
    let isHighlighted: Bool
    let onHover: (Bool) -> Void
    let onSelect: (_ openApp: Bool) -> Void

    @State private var revealed = false

    var body: some View {
        Button {
            onSelect(NSEvent.modifierFlags.contains(.option))
        } label: {
            VStack(spacing: RailMetrics.ringLabelGap) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.13), lineWidth: RailMetrics.ringLineWidth)

                    if let remaining = snapshot.remainingPercent {
                        Circle()
                            .trim(from: 0, to: revealed ? CGFloat(remaining) / 100 : 0)
                            .stroke(
                                meterColor(for: remaining),
                                style: StrokeStyle(lineWidth: RailMetrics.ringLineWidth, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }

                    ProviderLogo(provider: snapshot.provider, size: 18)
                        .foregroundStyle(.white.opacity(hasValue ? 0.95 : 0.4))

                    if let badge = statusBadge {
                        Image(systemName: badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 14, height: 14)
                            .background(Color.orange, in: Circle())
                            .offset(x: 16, y: -16)
                    }
                }
                .frame(width: RailMetrics.ringSize, height: RailMetrics.ringSize)
                .scaleEffect(isHighlighted ? 1.06 : 1)
                .animation(.easeOut(duration: 0.5), value: snapshot.remainingPercent)

                Text(valueLabel)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(hasValue ? 1 : 0.55))
                    .frame(height: RailMetrics.labelHeight)
            }
            .frame(width: RailMetrics.expandedWidth - 12, height: RailMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.12), value: isHighlighted)
        .onAppear {
            guard !revealed else { return }
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.easeOut(duration: 0.45).delay(0.04 + Double(revealIndex) * 0.04)) {
                    revealed = true
                }
            }
        }
        .help(helpText)
        .accessibilityLabel("\(snapshot.provider.displayName), \(helpText)")
    }

    private var hasValue: Bool { snapshot.remainingPercent != nil }

    private var valueLabel: String {
        if snapshot.health == .loading, !hasValue { return "…" }
        return snapshot.remainingPercent.map { "\($0)%" } ?? "—"
    }

    private var statusBadge: String? {
        switch snapshot.health {
        case .stale: "clock.fill"
        case .unavailable: hasValue ? "exclamationmark" : nil
        case .signedOut: "person.fill"
        case .permissionRequired: "lock.fill"
        default: nil
        }
    }

    private var helpText: String {
        if let remaining = snapshot.remainingPercent {
            return "\(remaining)% remaining · \(snapshot.health.shortLabel)"
        }
        return snapshot.health.shortLabel
    }

    private func meterColor(for remaining: Int) -> Color {
        switch remaining {
        case 0..<15: Color(red: 1, green: 0.27, blue: 0.23)
        case 15..<35: Color(red: 1, green: 0.62, blue: 0.04)
        default: Color(red: 0.19, green: 0.82, blue: 0.35)
        }
    }
}

// MARK: - Attachment column (detail card or settings), anchored to the hovered row

private struct AttachmentColumn: View {
    @EnvironmentObject private var store: UsageStore
    let attachment: EdgeAttachment?
    let providers: [ProviderID]
    let shapeHeight: CGFloat
    let edge: EdgeSide
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
                            .combined(with: .offset(x: edge == .right ? 8 : -8))
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

            content(for: attachment)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                    if contentHeight != newHeight {
                        DispatchQueue.main.async {
                            contentHeight = newHeight
                        }
                    }
                }
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
            return RailMetrics.rowCenterY(index: index)
        case .settings:
            return shapeHeight / 2
        }
    }
}

// MARK: - Detail card

struct UsageDetailCard: View {
    @EnvironmentObject private var store: UsageStore

    let snapshot: UsageSnapshot
    let openProvider: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderLogo(provider: snapshot.provider, size: 16)
                    .frame(width: 22, height: 22)

                Text("\(snapshot.provider.displayName) Usage")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.age(of: snapshot.observedAt, at: context.date))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .font(.caption)
            .foregroundStyle(.white)

            if let planLine {
                Text(planLine)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let message = snapshot.health.message, !snapshot.windows.isEmpty {
                Label(message, systemImage: "clock.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if snapshot.windows.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.windows) { window in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(window.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let reset = window.resetsAt {
                                    Text("Resets \(Self.absoluteReset(reset))")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }

                            UsageBar(remainingPercent: window.remainingPercent)
                                .padding(.vertical, 1)

                            HStack {
                                Text("\(window.usedPercent)% used · \(window.remainingPercent)% left")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                Spacer()
                                if let reset = window.resetsAt, reset > .now {
                                    Text("in \(Self.relativeReset(reset))")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                            }
                        }
                    }
                }
            }

            if let alternative = store.alternativeClaudeSource(for: snapshot) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(alternative.summary)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    GlassGroup(enabled: store.glassEnabled) {
                        HStack(spacing: 8) {
                            Button("Retry") { store.refresh(.claude) }
                                .glassControl(enabled: store.glassEnabled)
                            Button("Use \(alternative.label.lowercased())") { store.claudeSource = alternative }
                                .glassControl(enabled: store.glassEnabled)
                        }
                        .controlSize(.small)
                    }
                }
            }

            HStack {
                Spacer()
                Button(action: openProvider) {
                    Label("Open \(snapshot.provider.displayName)", systemImage: "arrow.up.forward.app")
                        .font(.caption2.weight(.semibold))
                }
                .glassControl(enabled: store.glassEnabled)
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .foregroundStyle(.white)
        .frame(width: RailMetrics.attachmentWidth - RailMetrics.pointerDepth)
        .modifier(RailGlass.Surface(
            shape: RoundedRectangle(cornerRadius: 20, style: .continuous),
            glassOpacity: store.glassOpacity,
            tint: RailGlass.cardTint(opacity: store.glassOpacity),
            interactive: false,
            enabled: store.glassEnabled
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(snapshot.provider.displayName) usage details")
    }

    private var emptyMessage: String {
        switch snapshot.health {
        case .unavailable(let message), .stale(let message), .signedOut(let message), .permissionRequired(let message):
            message
        case .loading: "Refreshing usage…"
        case .live: "No usage windows were reported."
        }
    }

    /// Plan tier name only; account/email/organization details are excluded for privacy.
    private var planLine: String? {
        snapshot.planName
    }

    private static func age(of date: Date, at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 3600 ? [.minute] : (seconds < 86_400 ? [.hour, .minute] : [.day, .hour])
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        return (formatter.string(from: seconds) ?? "") + " ago"
    }

    private static func absoluteReset(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 20 * 60 * 60 {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private static func relativeReset(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: .now)
            .replacingOccurrences(of: "in ", with: "")
    }
}

private struct UsageBar: View {
    let remainingPercent: Int

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(color)
                    .frame(width: max(4, proxy.size.width * CGFloat(100 - remainingPercent) / 100))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.5), value: remainingPercent)
    }

    private var color: Color {
        switch remainingPercent {
        case 0..<15: Color(red: 1, green: 0.27, blue: 0.23)
        case 15..<35: Color(red: 1, green: 0.62, blue: 0.04)
        default: Color(red: 0.19, green: 0.82, blue: 0.35)
        }
    }
}

// MARK: - Attached settings

private struct AttachedSettingsView: View {
    @EnvironmentObject private var store: UsageStore
    let actions: EdgePanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GaugeZWordmark(size: 17)

            VStack(spacing: 7) {
                ForEach(ProviderID.allCases) { provider in
                    HStack(spacing: 10) {
                        ProviderLogo(provider: provider, size: 14)
                            .frame(width: 18)
                        Text(provider.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Open") { store.open(provider) }
                            .glassControl(enabled: store.glassEnabled)
                            .controlSize(.mini)
                        Toggle(
                            "Enable \(provider.displayName)",
                            isOn: Binding(
                                get: { store.enabledProviders.contains(provider) },
                                set: { store.setProvider(provider, enabled: $0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(RailToggleStyle(glass: store.glassEnabled))
                    }
                }
            }

            settingRow("Claude") {
                Picker("Claude source", selection: $store.claudeSource) {
                    ForEach(ClaudeSource.allCases) { Text($0.label).tag($0) }
                }
            }

            settingRow("Show") {
                Picker("Show", selection: $store.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
            }

            HStack(spacing: 12) {
                settingRow("Edge") {
                    Picker("Edge", selection: $store.edgeSide) {
                        ForEach(EdgeSide.allCases) { Text($0.label).tag($0) }
                    }
                }

                settingRow("Style") {
                    Picker("Style", selection: $store.glassEnabled) {
                        Text("Liquid Glass").tag(true)
                        Text("Solid").tag(false)
                    }
                }
            }

            if store.glassEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Glass Transparency")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Text("\(Int(round((1.0 - store.glassOpacity) * 100)))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Slider(
                        value: Binding(
                            get: { 1.0 - store.glassOpacity },
                            set: { store.glassOpacity = 1.0 - $0 }
                        ),
                        in: 0.0...1.0
                    )
                    .controlSize(.small)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            indicatorColorBlock

            GlassGroup(enabled: store.glassEnabled) {
                HStack {
                    Button("Refresh", action: store.refresh)
                        .glassControl(enabled: store.glassEnabled)
                    Spacer()
                    Button("Diagnostics…") {
                        NotificationCenter.default.post(name: .gaugezOpenSettings, object: nil)
                    }
                    .glassControl(enabled: store.glassEnabled)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .foregroundStyle(.white)
        .frame(width: RailMetrics.attachmentWidth - RailMetrics.pointerDepth)
        .modifier(RailGlass.Surface(
            shape: RoundedRectangle(cornerRadius: 20, style: .continuous),
            glassOpacity: store.glassOpacity,
            tint: RailGlass.panelTint(opacity: store.glassOpacity),
            interactive: false,
            enabled: store.glassEnabled
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("GaugeZ settings")
    }

    private var indicatorColorBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Indicator Color")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(0..<store.indicatorVariants.count, id: \.self) { idx in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(store.indicatorVariants[idx])
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color(red: 0.13, green: 0.13, blue: 0.13).opacity(0.92))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                )
            }

            IndicatorColorPaletteView()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        settingRowBody(title, content: content)
    }

    private func settingRowBody<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
            content()
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IndicatorColorPaletteView: View {
    @EnvironmentObject private var store: UsageStore

    private static let presets: [(name: String, hex: String)] = [
        ("Blue", "#407CDE"),
        ("Green", "#2EA44F"),
        ("Purple", "#8B5CF6"),
        ("Amber", "#F59E0B"),
        ("Red", "#EF4444"),
        ("Cyan", "#06B6D4"),
        ("White", "#FFFFFF"),
        ("Black", "#18181B")
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.presets, id: \.hex) { preset in
                swatch(hex: preset.hex, name: preset.name)
            }
            customPickerButton
        }
        .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.colorDidChangeNotification)) { _ in
            if NSColorPanel.shared.isVisible {
                store.indicatorColorHex = NSColorPanel.shared.color.hexString
            }
        }
    }

    private func swatch(hex: String, name: String) -> some View {
        let selected = isSelected(hex)
        let isWhite = hex.uppercased() == "#FFFFFF"
        let isBlack = hex.uppercased() == "#18181B" || hex.uppercased() == "#000000"

        return Button {
            store.indicatorColorHex = hex
        } label: {
            ZStack {
                Circle()
                    .fill(Color(hex: hex) ?? .blue)
                    .frame(width: 17, height: 17)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isWhite ? Color.gray.opacity(0.4) : (isBlack ? Color.white.opacity(0.25) : Color.clear),
                                lineWidth: 1
                            )
                    )
                if selected {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: 21, height: 21)
                }
            }
            .frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private var customPickerButton: some View {
        let allHexes = Self.presets.map { $0.hex.uppercased() }
        let currentHex = store.indicatorColorHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let isCustom = !allHexes.contains(currentHex)

        return Button {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSColorPanel.shared
            panel.level = NSWindow.Level(max(panel.level.rawValue, NSWindow.Level.statusBar.rawValue + 1))
            panel.showsAlpha = false
            panel.isContinuous = true
            panel.color = NSColor(Color(hex: store.indicatorColorHex) ?? .blue)
            panel.makeKeyAndOrderFront(nil)
        } label: {
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                            center: .center
                        )
                    )
                    .frame(width: 17, height: 17)
                if isCustom {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: 21, height: 21)
                }
            }
            .frame(width: 21, height: 21)
        }
        .buttonStyle(.plain)
        .help("Custom color…")
    }

    private func isSelected(_ hex: String) -> Bool {
        store.indicatorColorHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == hex.uppercased()
    }
}

/// Switch that keeps its colour in a panel that never becomes the key window, where the
/// system switch would draw as inactive gray, styled with subtle glass depth when enabled.
private struct RailToggleStyle: ToggleStyle {
    var glass: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(
                        configuration.isOn
                            ? Color(red: 0.18, green: 0.82, blue: 0.38)
                            : (glass ? Color.white.opacity(0.14) : Color.white.opacity(0.18))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(glass ? 0.32 : 0.18),
                                        Color.white.opacity(glass ? 0.08 : 0.04)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: - Native Liquid Glass Controls & Containers

extension View {
    @ViewBuilder
    func glassControl(enabled: Bool = true) -> some View {
        if #available(macOS 26.0, *), enabled {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

struct GlassGroup<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *), enabled {
            GlassEffectContainer {
                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - Frosted glass

/// High-fidelity Liquid Glass surfaces built on vibrant behind-window blur with multi-layer
/// specular edge highlights and refractive sheen gradients.
enum RailGlass {
    /// Normalized opacity scaling:
    /// slider at 85% transparency (opacity 0.15) -> 0.02 (crystal clear!)
    /// slider at 15% transparency (opacity 0.85) -> 0.45 (smoked dark glass!)
    /// Scaled opacity:
    /// opacity 0.0 (100% transparency) -> Color.black.opacity(0.0) / crystal-clear glass!
    /// opacity 1.0 (0% transparency) -> Color.black.opacity(0.52) / dark smoked glass!
    static func tint(for opacity: Double) -> Color {
        let clamped = max(0.0, min(1.0, opacity))
        // 0.0 (100% transparency on slider) -> Color.clear (pure crystal-clear menu glass)
        // 1.0 (0% transparency on slider) -> 24% soft smoked tint
        return clamped > 0.01 ? Color.black.opacity(clamped * 0.24) : Color.clear
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

    /// Multi-layer liquid glass surface matching native macOS menu translucency.
    struct Frosted<S: Shape>: View {
        let shape: S
        var glassOpacity: Double = 0.50
        var tint: Color? = nil

        var body: some View {
            let clampedOpacity = max(0.0, min(1.0, glassOpacity))
            let tintColor = tint ?? RailGlass.tint(for: clampedOpacity)

            ZStack {
                // 1. Native macOS glass blur: scales opacity with slider so at 100% transparency
                // the dark graphite wash fades out and the vibrant wallpaper colors pass directly through!
                BehindWindowBlur(material: .popover)
                    .clipShape(shape)
                    .opacity(max(0.22, 0.28 + clampedOpacity * 0.72))

                // 2. Translucent tinted body (only adds dark tint when user reduces transparency)
                shape.fill(tintColor)

                // 3. Subtle optical surface sheen (soft top reflection)
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

                // 4. Clean specular edge highlight (light refraction without dark muddy strokes)
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

                // 5. Crisp subtle outer hairline matching macOS native menu border
                shape
                    .stroke(Color.black.opacity(0.20), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
        }
    }

    /// Frosted glass when enabled, otherwise the solid dark surface with a hairline edge.
    /// Dual-stage elevation: shadow is scaled with glass opacity so it never creates a dark backing inside transparent glass.
    struct Surface<S: Shape>: ViewModifier {
        let shape: S
        var glassOpacity: Double = 0.50
        var tint: Color? = nil
        let interactive: Bool
        let enabled: Bool
        var shadowed = true

        func body(content: Content) -> some View {
            let clampedOpacity = max(0.0, min(1.0, glassOpacity))
            content
                .background {
                    ZStack {
                        if shadowed {
                            // Shadow is softened and scaled with opacity to avoid darkening the transparent interior
                            shape.fill(.black.opacity(enabled ? clampedOpacity * 0.18 : 0.35))
                                .blur(radius: enabled ? 14 : 10)
                                .offset(y: 4)

                            shape.fill(.black.opacity(enabled ? clampedOpacity * 0.12 : 0.22))
                                .blur(radius: enabled ? 4 : 2)
                                .offset(y: 1)
                        }
                        if enabled {
                            Frosted(shape: shape, glassOpacity: glassOpacity, tint: tint)
                        } else {
                            shape.fill(Color(white: 0.04).opacity(0.97))
                            shape.stroke(.white.opacity(0.1), lineWidth: 1)
                        }
                    }
                }
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
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

// MARK: - Shapes

/// The black edge body: a concave shoulder that flows out of the screen edge, a straight inner
/// side with rounded corners, and a smaller concave foot back into the edge. Drawn for the
/// right edge and mirrored for the left.
struct EdgeNotchShape: Shape {
    let edge: EdgeSide

    func path(in rect: CGRect) -> Path {
        var path = EdgeNotchOutline.outline(in: rect)
        path.closeSubpath()
        return edge == .left ? path.mirrored(in: rect) : path
    }
}

/// The visible outline of the body (everything except the screen-edge side), used for the
/// hairline border.
struct EdgeNotchOutline: Shape {
    let edge: EdgeSide

    func path(in rect: CGRect) -> Path {
        let path = Self.outline(in: rect)
        return edge == .left ? path.mirrored(in: rect) : path
    }

    static func outline(in rect: CGRect) -> Path {
        let shoulder = RailMetrics.shoulderHeight
        let foot = RailMetrics.footHeight
        let corner = min(RailMetrics.bodyCornerRadius, rect.width / 2)
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
        Image(provider.logoAssetName)
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
    let edge: EdgeSide

    var body: some View {
        let shape = CardPointer(edge: edge)
        let outline = CardPointerOutline(edge: edge)

        ZStack {
            shape.fill(.black.opacity(store.glassEnabled ? store.glassOpacity * 0.18 : 0.35))
                .blur(radius: store.glassEnabled ? 6 : 8)
                .offset(y: 3)

            if store.glassEnabled {
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
                shape.fill(Color(white: 0.04).opacity(0.97))
                outline.stroke(.white.opacity(0.1), lineWidth: 1)
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
