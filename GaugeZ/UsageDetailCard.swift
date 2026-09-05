import AppKit
import SwiftUI

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

            if let headline = snapshot.headlineWindow {
                Text("\(headline.remainingPercent)% left · \(headline.label)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(headline.remainingPercent == 0 ? .red : .white)
            } else if snapshot.headlineWindowID != nil {
                Text("The selected window is not currently reported.")
                    .font(.caption).foregroundStyle(.orange)
            }

            if snapshot.windows.count > 1 || snapshot.headlineWindowID != nil {
                Picker("Rail number", selection: Binding(
                    get: { store.headlineWindows[snapshot.provider.rawValue] ?? "" },
                    set: { store.headlineWindows[snapshot.provider.rawValue] = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Most constrained window").tag("")
                    ForEach(snapshot.windows) { window in Text(window.label).tag(window.id) }
                    if let selected = snapshot.headlineWindowID, !snapshot.windows.contains(where: { $0.id == selected }) {
                        Text("Selected window (unavailable)").tag(selected)
                    }
                }
                .font(.caption).controlSize(.small)
            }

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

            if store.activityEnabled, snapshot.provider == .claude {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CLAUDE CODE SESSIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    let sessions = store.activity(for: snapshot.provider)
                    if sessions.isEmpty {
                        Text("No verifiable session activity available.").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name).font(.caption.weight(.medium))
                            Text("\(session.state.rawValue) · \(session.project)")
                                .foregroundStyle(session.state == .waiting ? .orange : .secondary)
                            if session.state == .waiting, let reason = session.waitingReason { Text(reason) }
                        }
                        .font(.caption2)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 4)
            }

            if let alternative = store.alternativeClaudeSource(for: snapshot) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(alternative.summary)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    GlassGroup(enabled: store.glassEnabled) {
                        HStack(spacing: 8) {
                            Button("Use \(alternative.label.lowercased())") { store.claudeSource = alternative }
                                .glassControl(enabled: store.glassEnabled)
                        }
                        .controlSize(.small)
                    }
                }
            }

            if let error = store.actionErrors[snapshot.provider] {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                Button(store.refreshing.contains(snapshot.provider) ? "Refreshing…" : "Refresh") { store.refresh(snapshot.provider) }
                    .disabled(store.refreshing.contains(snapshot.provider) || store.nextRetry(for: snapshot.provider) != nil)
                    .glassControl(enabled: store.glassEnabled)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let remainingPercent: Int

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, proxy.size.width * CGFloat(100 - remainingPercent) / 100))
            }
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: remainingPercent)
    }

    private var color: Color { .quota(remainingPercent: remainingPercent) }
}

