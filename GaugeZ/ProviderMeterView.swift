import AppKit
import SwiftUI

struct ProviderMeterView: View {
    @EnvironmentObject private var store: UsageStore
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
                        .stroke(snapshot.remainingPercent == 0 ? Color.red : .white.opacity(0.13), lineWidth: RailMetrics.ringLineWidth)

                    if let remaining = snapshot.remainingPercent {
                        Circle()
                            .trim(from: 0, to: revealed ? CGFloat(remaining) / 100 : 0)
                            .stroke(
                                Color.quota(remainingPercent: remaining),
                                style: StrokeStyle(lineWidth: RailMetrics.ringLineWidth, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }

                    ProviderLogo(provider: snapshot.provider, size: 18)
                        .foregroundStyle(.white.opacity(hasValue ? 0.95 : 0.4))

                    if let activity = knownActivity {
                        Image(systemName: activity.state == .waiting ? "hand.raised.fill" : (activity.state == .working ? "bolt.fill" : "minus"))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(activity.state == .waiting ? .orange : .white)
                            .padding(4)
                            .background(.black, in: Circle())
                            .offset(x: -17, y: -16)
                            .symbolEffect(.pulse, options: .repeating, isActive: activity.state == .working && !reduceMotion)
                            .accessibilityLabel(activity.state.rawValue)
                    }
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
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: snapshot.remainingPercent)

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
        .contextMenu {
            Button("Refresh") { store.refresh(snapshot.provider) }
                .disabled(store.refreshing.contains(snapshot.provider) || store.nextRetry(for: snapshot.provider) != nil)
            Button("Open \(snapshot.provider.displayName)") { store.open(snapshot.provider) }
        }
        .help(helpText)
        .accessibilityLabel("\(snapshot.provider.displayName), \(helpText)")
    }

    private var hasValue: Bool { snapshot.remainingPercent != nil }

    private var valueLabel: String {
        if snapshot.health == .loading, !hasValue { return "…" }
        return snapshot.remainingPercent.map { "\($0)%" } ?? "—"
    }

    /// The most urgent session whose state is actually reported. Session records that omit
    /// status/tempo (e.g. desktop-hosted Claude Code) are skipped rather than shown as "?".
    private var knownActivity: ActivitySession? {
        store.activity(for: snapshot.provider).first { $0.state != .unknown }
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
            let window = snapshot.headlineWindow?.label ?? "Quota"
            let activity = knownActivity.map { " · " + $0.state.rawValue } ?? ""
            return "\(remaining)% remaining · \(window) · \(snapshot.health.shortLabel)\(activity)"
        }
        if snapshot.headlineWindowID != nil { return "Selected quota window unavailable" }
        return snapshot.health.shortLabel
    }

}

extension Color {
    /// Shared red/amber/green scale for remaining quota, used by the rail rings and detail bars.
    static func quota(remainingPercent: Int) -> Color {
        switch remainingPercent {
        case 0..<15: Color(red: 1, green: 0.27, blue: 0.23)
        case 15..<35: Color(red: 1, green: 0.62, blue: 0.04)
        default: Color(red: 0.19, green: 0.82, blue: 0.35)
        }
    }
}

