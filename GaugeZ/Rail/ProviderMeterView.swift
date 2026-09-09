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
        let scale = CGFloat(store.railScale)
        let ringSize = RailMetrics.ringSize(scale: scale)
        let lineWidth = RailMetrics.ringLineWidth(scale: scale)
        let logoSize = max(12.0, (18.0 * scale).rounded())
        let fontSize = max(9.0, (13.0 * scale).rounded())
        let badgeScale = max(0.75, min(1.25, scale))

        return Button {
            onSelect(NSEvent.modifierFlags.contains(.option))
        } label: {
            VStack(spacing: RailMetrics.ringLabelGap(scale: scale)) {
                ZStack {
                    Circle()
                        .stroke(snapshot.remainingPercent == 0 ? Color.red : .white.opacity(0.13), lineWidth: lineWidth)

                    if let remaining = snapshot.remainingPercent {
                        Circle()
                            .trim(from: 0, to: revealed ? CGFloat(remaining) / 100 : 0)
                            .stroke(
                                Color.quota(remainingPercent: remaining),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }

                    ProviderLogo(provider: snapshot.provider, size: logoSize)
                        .foregroundStyle(.white.opacity(hasValue ? 0.95 : 0.4))

                    if let activity = knownActivity {
                        Image(systemName: activity.state == .waiting ? "hand.raised.fill" : (activity.state == .working ? "bolt.fill" : "minus"))
                            .font(.system(size: 9 * badgeScale, weight: .bold))
                            .foregroundStyle(activity.state == .waiting ? .orange : .white)
                            .padding(4 * badgeScale)
                            .background(.black, in: Circle())
                            .offset(x: -17 * scale, y: -16 * scale)
                            .symbolEffect(.pulse, options: .repeating, isActive: activity.state == .working && !reduceMotion)
                            .accessibilityLabel(activity.state.localizedLabel)
                    }
                    if let badge = statusBadge {
                        Image(systemName: badge)
                            .font(.system(size: 8 * badgeScale, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 14 * badgeScale, height: 14 * badgeScale)
                            .background(Color.orange, in: Circle())
                            .offset(x: 16 * scale, y: -16 * scale)
                    }
                }
                .frame(width: ringSize, height: ringSize)
                .scaleEffect(isHighlighted ? 1.06 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: snapshot.remainingPercent)

                Text(valueLabel)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(hasValue ? 1 : 0.55))
                    .frame(height: RailMetrics.labelHeight(scale: scale))
            }
            .frame(width: max(36, RailMetrics.expandedWidth(scale: scale) - 12), height: RailMetrics.rowHeight(scale: scale))
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
            Button("Refresh") { store.retry(snapshot.provider) }
                .disabled(store.refreshing.contains(snapshot.provider) || store.nextRetry(for: snapshot.provider) != nil)
            Button("Open \(snapshot.provider.displayName)") { store.open(snapshot.provider) }
        }
        .help(helpText)
        .accessibilityLabel("\(snapshot.provider.displayName), \(helpText)")
    }

    private var hasValue: Bool { snapshot.remainingPercent != nil }

    private var valueLabel: String {
        if snapshot.health == .loading, !hasValue { return "…" }
        if let count = snapshot.derivedRequestCount { return "~\(count)" }
        return snapshot.remainingPercent.map { "\(PercentCopy.text($0))%" } ?? "—"
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
            let window = snapshot.headlineWindow?.label ?? String(localized: "Quota", bundle: .language)
            let activity = knownActivity.map { " · " + $0.state.localizedLabel } ?? ""
            let format = String(localized: "%@%% remaining · %@ · %@%@", bundle: .language)
            return String.localizedStringWithFormat(format, PercentCopy.text(remaining), window, snapshot.health.shortLabel, activity)
        }
        if let count = snapshot.derivedRequestCount {
            let format = String(localized: "Derived: %lld model turns today · no published quota", bundle: .language)
            return String.localizedStringWithFormat(format, Int64(count))
        }
        if snapshot.headlineWindowID != nil { return String(localized: "Selected quota window unavailable", bundle: .language) }
        return snapshot.health.shortLabel
    }

}

extension Color {
    /// Shared red/amber/green scale for remaining quota, used by the rail rings and detail bars.
    static func quota(remainingPercent: Double) -> Color {
        switch remainingPercent {
        case 0..<15: Color(red: 1, green: 0.27, blue: 0.23)
        case 15..<35: Color(red: 1, green: 0.62, blue: 0.04)
        default: Color(red: 0.19, green: 0.82, blue: 0.35)
        }
    }
}

