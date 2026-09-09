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

            if let event = store.completionPeek, event.session.provider == snapshot.provider {
                Button { SessionFocus.activate(event.session) } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.reason == .blocked ? String(localized: "Needs your input", bundle: .language) : event.session.isInferred ? String(localized: "Activity paused · inferred", bundle: .language) : String(localized: "Session finished", bundle: .language)).font(.caption.weight(.semibold))
                            Text(event.session.name + " · " + String(localized: "Open app", bundle: .language)).font(.caption2).lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: event.reason == .blocked ? "hand.raised.fill" : "checkmark.circle.fill")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(event.reason == .blocked ? .orange : .green)
            }
            if let count = snapshot.derivedRequestCount {
                Text("~\(count) model turns today · derived from local transcripts")
                    .font(.caption.weight(.semibold))
                Text("Quota unavailable. This is a local count, with no published limit.").font(.caption2).foregroundStyle(.secondary)
            }
            if let headline = snapshot.headlineWindow {
                Text("\(PercentCopy.text(headline.remainingPercent))% left · \(headline.label)")
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
                    if let defaultID = store.snapshots[snapshot.provider]?.headlineWindowID,
                       let window = snapshot.windows.first(where: { $0.id == defaultID }) {
                        Text("Default: \(window.label)").tag("")
                    } else {
                        Text("Most constrained window").tag("")
                    }
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

            if snapshot.windows.isEmpty && snapshot.derivedRequestCount == nil {
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
                                Text("\(PercentCopy.text(window.usedPercent))% used · \(PercentCopy.text(window.remainingPercent))% left")
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

            if let cost = snapshot.costInfo {
                VStack(alignment: .leading, spacing: 6) {
                    Divider().opacity(0.15).padding(.vertical, 2)

                    HStack(alignment: .firstTextBaseline) {
                        Text("Session Usage")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if let formattedCost = cost.formattedCost {
                            Text(formattedCost)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                    }

                    if let details = cost.sessionDetailLine {
                        Text(details)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }

                    if let balance = cost.formattedBalance, (cost.prepaidBalance ?? 0) > 0 {
                        HStack {
                            Text("Prepaid Balance")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                            Spacer()
                            Text("\(balance) credits")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
            }

            if store.activityEnabled, snapshot.provider.supportsActivity {
                let sessions = store.activity(for: snapshot.provider)
                let cap = SessionListCap.count(visibleHeight: Self.displayHeight(for: store))
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.sessionsTitle(for: snapshot.provider)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if sessions.isEmpty {
                        Text(snapshot.provider.activityIsInferred
                             ? "No recent writes from \(snapshot.provider.displayName)."
                             : "No verifiable session activity available.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    // Waiting first, then working, so what the cap hides is what matters least.
                    ForEach(sessions.prefix(cap)) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name).font(.caption.weight(.medium))
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(Self.sessionLine(session, now: context.date))
                            }
                            .foregroundStyle(session.state == .waiting ? .orange : .secondary)
                            if session.state == .waiting, let reason = session.waitingReason { Text(reason) }
                        }
                        .font(.caption2)
                        .accessibilityElement(children: .combine)
                    }
                    if sessions.count > cap {
                        Text("and \(sessions.count - cap) more")
                            .font(.caption2).foregroundStyle(.secondary)
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
                Button(store.refreshing.contains(snapshot.provider) ? "Refreshing…" : "Refresh") { store.retry(snapshot.provider) }
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
        case .loading: String(localized: "Refreshing usage…", bundle: .language)
        case .live: String(localized: "No usage windows were reported.", bundle: .language)
        }
    }

    /// Plan tier name only; account/email/organization details are excluded for privacy.
    private var planLine: String? {
        snapshot.planName
    }

    private static func sessionsTitle(for provider: ProviderID) -> String {
        switch provider.kind {
        case .claude: String(localized: "CLAUDE CODE SESSIONS", bundle: .language)
        default: String.localizedStringWithFormat(String(localized: "%@ SESSIONS", bundle: .language), provider.displayName.uppercased())
        }
    }

    /// "Working · GaugeZ · 6 min", with inferred states marked as such.
    static func sessionLine(_ session: ActivitySession, now: Date) -> String {
        let stateText = session.isInferred
            ? String.localizedStringWithFormat(String(localized: "%@ (inferred)", bundle: .language), session.state.localizedLabel)
            : session.state.localizedLabel
        var parts = [stateText, session.project]
        if let since = session.since, session.state != .unknown {
            parts.append(ElapsedCopy.text(since: since, now: now))
        }
        return parts.joined(separator: " · ")
    }

    private static func displayHeight(for store: UsageStore) -> CGFloat {
        let screen = NSScreen.screens.first { DisplayChoice.identifier(for: $0) == store.selectedDisplayID } ?? NSScreen.main
        return screen?.visibleFrame.height ?? 800
    }

    private static func age(of date: Date, at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "just now", bundle: .language) }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 3600 ? [.minute] : (seconds < 86_400 ? [.hour, .minute] : [.day, .hour])
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        let formatted = formatter.string(from: seconds) ?? ""
        return String.localizedStringWithFormat(String(localized: "%@ ago", bundle: .language), formatted)
    }

    private static func absoluteReset(_ date: Date) -> String {
        ResetCopy.absolute(date)
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
    let remainingPercent: Double

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

