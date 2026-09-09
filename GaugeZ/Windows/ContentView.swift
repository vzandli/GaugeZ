import SwiftUI

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general = "General"
    case providers = "Providers"
    case appearance = "Appearance"
    case diagnostics = "Diagnostics"
    case updates = "Updates"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .providers: "square.stack.3d.up.fill"
        case .appearance: "paintbrush.pointed.fill"
        case .diagnostics: "waveform.path.ecg"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

private enum SettingsPalette {
    static let background = Color(red: 0.048, green: 0.055, blue: 0.071)
    static let sidebar = Color(red: 0.034, green: 0.040, blue: 0.054)
    static let card = Color.white.opacity(0.052)
    static let cardStroke = Color.white.opacity(0.085)
    static let divider = Color.white.opacity(0.07)
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)
    static let accent = Color(red: 0.27, green: 0.58, blue: 1.00)
    /// Native `.switch` toggles are avoided here; see `RailToggleStyle`.
    static let toggle = RailToggleStyle(glass: false, onColor: accent, width: 38, height: 22)
    static let smallToggle = RailToggleStyle(glass: false, onColor: accent, width: 30, height: 18)
}

/// GaugeZ's standalone settings workspace.
struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateManager: UpdateManager
    @State private var destination = SettingsDestination(rawValue: ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_SETTINGS"] ?? "") ?? .providers

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $destination, enabledCount: store.enabledProviders.count)

            Rectangle()
                .fill(SettingsPalette.divider)
                .frame(width: 1)

            Group {
                switch destination {
                case .general:
                    GeneralSettingsPage(store: store)
                case .providers:
                    ProvidersSettingsPage(store: store)
                case .appearance:
                    AppearanceSettingsPage(store: store)
                case .diagnostics:
                    DiagnosticsSettingsPage(store: store)
                case .updates:
                    UpdatesSettingsPage(updateManager: updateManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack(alignment: .topTrailing) {
                    SettingsPalette.background
                    RadialGradient(
                        colors: [SettingsPalette.accent.opacity(0.08), .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 390
                    )
                }
                .ignoresSafeArea()
            }
        }
        .environmentObject(store)
        .preferredColorScheme(.dark)
        .tint(SettingsPalette.accent)
        .frame(minWidth: 900, idealWidth: 980, minHeight: 560, idealHeight: 680)
    }
}

private struct UpdatesSettingsPage: View {
    @ObservedObject var updateManager: UpdateManager

    var body: some View {
        SettingsPageContainer {
            SettingsPageHeader(
                eyebrow: "SOFTWARE UPDATE",
                title: "Updates",
                subtitle: "Keep GaugeZ current with the latest improvements and fixes."
            )

            VStack(spacing: 0) {
                SettingsControlRow(
                    title: "Automatic checks",
                    subtitle: "Periodically check for new versions in the background"
                ) {
                    Toggle("", isOn: $updateManager.automaticallyChecksForUpdates)
                        .labelsHidden()
                        .toggleStyle(SettingsPalette.toggle)
                }

                SettingsRowDivider()

                SettingsControlRow(
                    title: "Current version",
                    subtitle: updateManager.currentVersion
                ) {
                    Button("Check Now") {
                        updateManager.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updateManager.canCheckForUpdates)
                }
            }
            .padding(.horizontal, 18)
            .settingsCard()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(SettingsPalette.accent)
                Text("Updates are verified with GaugeZ's signing key before they are installed.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsDestination
    let enabledCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                .shadow(color: SettingsPalette.accent.opacity(0.24), radius: 12, y: 5)

                VStack(alignment: .leading, spacing: 1) {
                    GaugeZWordmark(size: 18, primaryColor: SettingsPalette.primary)
                    Text("Settings")
                        .font(.caption)
                        .foregroundStyle(SettingsPalette.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 25)

            Text("PREFERENCES")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(SettingsPalette.tertiary)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            VStack(spacing: 5) {
                ForEach(SettingsDestination.allCases) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            selection = item
                        }
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 17)
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 4)
                            if item == .providers {
                                Text("\(enabledCount)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(selection == item ? .white : SettingsPalette.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        Color.white.opacity(selection == item ? 0.15 : 0.07),
                                        in: Capsule()
                                    )
                            }
                        }
                        .foregroundStyle(selection == item ? .white : SettingsPalette.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(SettingsPalette.accent.opacity(0.18))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(SettingsPalette.accent.opacity(0.22), lineWidth: 1)
                                    }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Local by design")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SettingsPalette.secondary)
                    Text("Credentials stay on this Mac")
                        .font(.system(size: 9.5))
                        .foregroundStyle(SettingsPalette.tertiary)
                }
            }
            .padding(16)
        }
        .frame(width: 188)
        .frame(maxHeight: .infinity)
        .background(SettingsPalette.sidebar.ignoresSafeArea())
    }
}

private struct ProvidersSettingsPage: View {
    @ObservedObject var store: UsageStore
    @AppStorage("hasSeenIntroduction") private var hasSeenIntroduction = false

    private var liveCount: Int {
        store.visibleProviders.filter { store.snapshot(for: $0).health == .live }.count
    }

    var body: some View {
        SettingsPageContainer {
            SettingsPageHeader(
                eyebrow: "INTEGRATIONS",
                title: "Connected providers",
                subtitle: "Choose which AI subscriptions appear in your edge rail."
            ) {
                Button(action: store.refresh) {
                    Label("Refresh all", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if !hasSeenIntroduction {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Welcome to GaugeZ").font(.headline)
                    Text("Hover the screen-edge tab to see quota remaining. Select a provider for its windows and reset times. The rail shows your most constrained window unless you choose another.")
                    Text("GaugeZ uses the sign-in from each enabled provider. Disable any you do not want it to read. Activity monitoring is optional and stays on this Mac.")
                        .foregroundStyle(SettingsPalette.secondary)
                    Text("For keyboard access, choose Usage… in the GaugeZ menu bar menu.")
                    Button("Got it") { hasSeenIntroduction = true }.buttonStyle(.borderedProminent)
                }
                .font(.callout)
                .padding(16)
                .settingsCard()
            }

            HStack(spacing: 8) {
                SummaryPill(
                    text: "\(store.enabledProviders.count) enabled",
                    symbol: "checkmark.circle.fill",
                    color: SettingsPalette.accent
                )
                SummaryPill(
                    text: "\(liveCount) live",
                    symbol: "bolt.fill",
                    color: .green
                )
            }

            VStack(spacing: 10) {
                ForEach(store.providerOrder) { provider in
                    ProviderSettingsRow(
                        provider: provider,
                        snapshot: store.snapshot(for: provider),
                        enabled: Binding(
                            get: { store.enabledProviders.contains(provider) },
                            set: { store.setProvider(provider, enabled: $0) }
                        ),
                        alertsEnabled: Binding(
                            get: { !store.mutedAlertProviders.contains(provider.rawValue) },
                            set: { enabled in
                                if enabled { store.mutedAlertProviders.remove(provider.rawValue) }
                                else { store.mutedAlertProviders.insert(provider.rawValue) }
                            }
                        ),
                        claudeSource: $store.claudeSource,
                        canMoveUp: store.providerOrder.first != provider,
                        canMoveDown: store.providerOrder.last != provider,
                        move: { store.moveProvider(provider, by: $0) },
                        openProvider: { store.open(provider) }
                    )
                }
            }

            Label(
                "Disabling a provider removes it from the rail and clears its cached values.",
                systemImage: "info.circle"
            )
            .font(.system(size: 11.5))
            .foregroundStyle(SettingsPalette.tertiary)
            .padding(.top, 2)
        }
    }
}

private struct ProviderSettingsRow: View {
    let provider: ProviderID
    let snapshot: UsageSnapshot
    @Binding var enabled: Bool
    @Binding var alertsEnabled: Bool
    @Binding var claudeSource: ClaudeSource
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let openProvider: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProviderLogo(provider: provider, size: 20)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(provider.displayName)
                    .help(provider.sourceDescription)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primary)
                    .lineLimit(2)
                HealthBadge(health: snapshot.health)
            }
            .frame(width: 100, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(enabled ? SettingsPalette.primary : SettingsPalette.secondary)
                Text(statusDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 120, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text("SOURCE")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(SettingsPalette.tertiary)

                if provider == .claude, enabled {
                    Picker("Claude source", selection: $claudeSource) {
                        ForEach(ClaudeSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .help(claudeSource.summary)
                } else {
                    Text(enabled ? snapshot.source : "Disabled")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SettingsPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(enabled ? snapshot.source : "Provider disabled")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("ALERTS")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(SettingsPalette.tertiary)
                Toggle("Usage alerts for \(provider.displayName)", isOn: $alertsEnabled)
                    .labelsHidden()
                    .toggleStyle(SettingsPalette.smallToggle)
                    .help("Notify at 20% and 0% remaining")
                    .disabled(!enabled)
            }
            .padding(.trailing, 6)

            reorderControls

            Button("Open", action: openProvider)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!enabled)

            Toggle("Enable \(provider.displayName)", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(SettingsPalette.toggle)
                .controlSize(.small)
            }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .settingsCard()
        .opacity(enabled ? 1 : 0.62)
        .animation(.easeOut(duration: 0.18), value: enabled)
    }

    /// Stacked up/down chevrons that shift the provider's place in the rail.
    private var reorderControls: some View {
        VStack(spacing: 2) {
            reorderButton(systemImage: "chevron.up", enabled: canMoveUp, label: "Move \(provider.displayName) up in the rail") { move(-1) }
            reorderButton(systemImage: "chevron.down", enabled: canMoveDown, label: "Move \(provider.displayName) down in the rail") { move(1) }
        }
        .padding(.trailing, 2)
    }

    private func reorderButton(systemImage: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? SettingsPalette.secondary : SettingsPalette.tertiary.opacity(0.5))
                .frame(width: 22, height: 16)
                .background(Color.white.opacity(enabled ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var statusTitle: String {
        guard enabled else { return "Not shown in rail" }
        if let remaining = snapshot.remainingPercent {
            return "\(PercentCopy.text(remaining))% remaining"
        }
        return snapshot.health.shortLabel
    }

    private var statusDetail: String {
        guard enabled else { return "Enable this provider to start tracking usage." }
        var details: [String] = []
        if let plan = snapshot.planName { details.append(plan) }
        if snapshot.health != .live, snapshot.remainingPercent != nil {
            details.append(snapshot.health.shortLabel)
        }
        if details.isEmpty { details.append(snapshot.source) }
        return details.joined(separator: " · ")
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        SettingsPageContainer {
            SettingsPageHeader(
                eyebrow: "APPLICATION",
                title: "General",
                subtitle: "How GaugeZ starts, where it shows itself, and how it follows your sessions."
            )

            SettingsGroup("Startup") {
                SettingsControlRow(title: "Launch at login", subtitle: "Keep GaugeZ available after signing in") {
                    Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                        .labelsHidden().toggleStyle(SettingsPalette.toggle)
                }
                if let problem = store.loginProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange).padding(12)
                }
                SettingsRowDivider()
                SettingsControlRow(title: "App presence", subtitle: store.appPresence.explanation) {
                    Picker("App presence", selection: $store.appPresence) {
                        ForEach(AppPresence.allCases) { presence in Text(presence.title).tag(presence) }
                    }
                    .labelsHidden().frame(width: 130)
                }
            }

            SettingsGroup("Sessions") {
                SettingsControlRow(title: "Session activity", subtitle: "Show Claude Code, Cursor, Grok Build, Codex, and Antigravity session states from local data. Claude may read a bounded transcript tail when status is missing; transcript text stays on this Mac. Codex and Antigravity states are inferred from recent writes.") {
                    Toggle("Show session activity", isOn: $store.activityEnabled).labelsHidden().toggleStyle(SettingsPalette.toggle)
                }
                SettingsRowDivider()
                SettingsControlRow(title: "Session peek", subtitle: "Open the rail for five seconds when work finishes or needs input. Click its provider to raise the owning app.") {
                    Toggle("Session peek", isOn: $store.sessionPeekEnabled).labelsHidden().toggleStyle(SettingsPalette.toggle).disabled(!store.activityEnabled)
                }
                SettingsRowDivider()
                SettingsControlRow(title: "Session sounds", subtitle: "Chime when a session finishes or needs input. Only reported sessions chime; inferred Codex and Antigravity activity never does.") {
                    Toggle("Session sounds", isOn: $store.sessionChimeEnabled).labelsHidden().toggleStyle(SettingsPalette.toggle).disabled(!store.activityEnabled)
                }
                if store.sessionChimeEnabled {
                    SettingsRowDivider()
                    ChimePickerRow(title: "Finished work", subtitle: "Plays when a session completes a turn", selection: $store.finishedChime) {
                        store.previewChime(.finished)
                    }
                    SettingsRowDivider()
                    ChimePickerRow(title: "Needs input", subtitle: "Plays when a session is waiting on you", selection: $store.waitingChime) {
                        store.previewChime(.blocked)
                    }
                }
            }
        }
    }
}

/// A system-sound menu with a play button beside it, so a pick can be heard before it fires for real.
private struct ChimePickerRow: View {
    @EnvironmentObject private var store: UsageStore
    let title: String
    let subtitle: String
    @Binding var selection: String
    let preview: () -> Void

    var body: some View {
        SettingsControlRow(title: title, subtitle: subtitle) {
            HStack(spacing: 8) {
                Picker(title, selection: $selection) {
                    ForEach(SessionChime.systemSounds, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)

                Button(action: preview) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Play \(selection)")
                .accessibilityLabel("Play \(selection)")
            }
            .disabled(!store.activityEnabled)
        }
        .padding(.leading, 16)
    }
}

private struct AppearanceSettingsPage: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        SettingsPageContainer {
            SettingsPageHeader(
                eyebrow: "PERSONALIZATION",
                title: "Appearance",
                subtitle: "Where the rail lives on your screen and how it looks."
            )

            SettingsGroup("Placement") {
                SettingsControlRow(title: "Display", subtitle: "Returns to this display when it reconnects") {
                    Picker("Display", selection: $store.selectedDisplayID) {
                        ForEach(store.availableDisplays) { display in Text(display.name).tag(display.id) }
                        if !store.availableDisplays.contains(where: { $0.id == store.selectedDisplayID }) {
                            Text("Saved display (disconnected)").tag(store.selectedDisplayID)
                        }
                    }
                    .labelsHidden().frame(width: 170)
                }
                SettingsRowDivider()
                SettingsControlRow(title: "Rail visibility", subtitle: "When the edge rail appears") {
                    Picker("Rail visibility", selection: $store.displayMode) {
                        ForEach(DisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 152)
                }
                SettingsRowDivider()
                SettingsControlRow(title: "Screen edge", subtitle: "Anchor GaugeZ to any screen edge") {
                    Picker("Screen edge", selection: $store.edgeSide) {
                        ForEach(EdgeSide.allCases) { edge in
                            Text(edge.label).tag(edge)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    // Sized to its four segments; a fixed width sized for two overflowed the row.
                    .fixedSize()
                }
                SettingsRowDivider()
                SettingsControlRow(
                    title: store.edgeSide.isHorizontal ? "Horizontal position" : "Vertical position",
                    subtitle: "Position along the screen edge"
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $store.verticalPosition, in: 0...1)
                            .frame(width: 120)
                            .controlSize(.small)

                        Button("Center") {
                            withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
                                store.verticalPosition = 0.5
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(abs(store.verticalPosition - 0.5) < 0.005)
                    }
                }
            }

            SettingsGroup("Look") {
                SettingsControlRow(title: "Notch size", subtitle: "Use the slider or drag the notch's inner edge") {
                    HStack(spacing: 8) {
                        Slider(value: $store.railScale, in: 0.70...1.40, step: 0.05)
                            .frame(width: 120)
                            .controlSize(.small)

                        Text("\(Int(round(store.railScale * 100)))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(SettingsPalette.secondary)
                            .frame(width: 38, alignment: .trailing)

                        Button("Reset", action: store.resetRailScale)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.railScale == 1.0)
                    }
                }
                SettingsRowDivider()
                SettingsControlRow(title: "Surface", subtitle: "Choose the rail material") {
                    Picker("Surface", selection: $store.glassEnabled) {
                        Text("Glass").tag(true)
                        Text("Solid").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 142)
                }

                if store.glassEnabled {
                    SettingsRowDivider()

                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Glass transparency")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(SettingsPalette.primary)
                                Text("Balance clarity and depth")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(SettingsPalette.tertiary)
                            }
                            Spacer()
                            Text("\(transparencyPercent)%")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(SettingsPalette.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { 1.0 - store.glassOpacity },
                                set: { store.glassOpacity = 1.0 - $0 }
                            ),
                            in: 0...1
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                SettingsRowDivider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Indicator color")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SettingsPalette.primary)
                            Text("Applied as a tonal spectrum")
                                .font(.system(size: 10.5))
                                .foregroundStyle(SettingsPalette.tertiary)
                        }
                        Spacer()
                        IndicatorSpectrum(colors: store.indicatorVariants)
                    }
                    IndicatorColorPaletteView()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private var transparencyPercent: Int {
        Int(round((1.0 - store.glassOpacity) * 100))
    }
}

/// A titled card of settings rows.
private struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(SettingsPalette.tertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity)
            .settingsCard()
        }
    }
}

private struct IndicatorSpectrum: View {
    let colors: [Color]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(colors.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(colors[index])
                    .frame(width: 8, height: 8)
            }
        }
        .padding(5)
        .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct DiagnosticsSettingsPage: View {
    @ObservedObject var store: UsageStore
    @State private var confirmsErase = false
    @State private var eraseError: String?

    var body: some View {
        SettingsPageContainer {
            SettingsPageHeader(
                eyebrow: "SYSTEM STATUS",
                title: "Diagnostics",
                subtitle: "See where each value came from and when it was last observed."
            ) {
                Button(action: store.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            Button("Erase all data and quit…", role: .destructive) { confirmsErase = true }
                .confirmationDialog("Erase GaugeZ data and quit?", isPresented: $confirmsErase) {
                    Button("Erase all data and quit", role: .destructive) {
                        Task { do { try await store.eraseAllDataAndQuit() } catch { eraseError = error.localizedDescription } }
                    }
                } message: {
                    Text("Removes GaugeZ settings, cached readings, and launch-at-login registration. Your provider accounts and credentials stay in their own apps.")
                }
            if let eraseError { Text(eraseError).foregroundStyle(.red).font(.caption) }

            VStack(spacing: 0) {
                ForEach(Array(store.connectedProviders.enumerated()), id: \.element) { index, provider in
                    if index > 0 { SettingsRowDivider() }
                    DiagnosticsRow(snapshot: store.snapshot(for: provider))
                }
            }
            .frame(maxWidth: .infinity)
            .settingsCard()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Color.green.opacity(0.8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Privacy first")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsPalette.primary)
                    Text("GaugeZ stores only normalized usage observations—never tokens, credentials, or raw responses.")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.10), lineWidth: 1)
            }
        }
    }
}

/// One provider in the diagnostics list: identity and health on the first line, where the
/// reading came from on the second, and any note from the provider on a third.
private struct DiagnosticsRow: View {
    @EnvironmentObject private var store: UsageStore
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProviderLogo(provider: snapshot.provider, size: 16)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(snapshot.provider.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsPalette.primary)
                    HealthBadge(health: snapshot.health)
                }

                Text(details.joined(separator: "  ·  "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = store.actionErrors[snapshot.provider] {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let message = snapshot.health.message {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SettingsPalette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                Button("Retry") { store.retry(snapshot.provider) }
                    .disabled(!store.enabledProviders.contains(snapshot.provider) || store.refreshing.contains(snapshot.provider) || store.nextRetry(for: snapshot.provider) != nil)
                Button("Open app") { store.open(snapshot.provider) }
                Button("Forget reading") { store.forget(snapshot.provider) }
                    .help("Clears GaugeZ’s cached reading. The enabled provider can refresh again later.")
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .padding(.top, 7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var details: [String] {
        var parts = [snapshot.source]
        if let window = snapshot.headlineWindow { parts.append(window.label) }
        if let plan = snapshot.planName { parts.append(plan) }
        if let retry = store.nextRetry(for: snapshot.provider) {
            parts.append("Retry at " + retry.formatted(date: .omitted, time: .standard))
        } else {
            parts.append("Observed " + snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))
        }
        return parts
    }
}

private struct SettingsPageContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }
}

private struct SettingsPageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.35)
                    .foregroundStyle(SettingsPalette.accent)
                Text(title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(SettingsPalette.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.secondary)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

private extension SettingsPageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

private struct SettingsControlRow<Control: View>: View {
    let title: String
    let subtitle: String
    let control: Control

    init(title: String, subtitle: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsPalette.primary)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsPalette.tertiary)
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsPalette.divider)
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

private struct SummaryPill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.09), in: Capsule())
            .overlay {
                Capsule().strokeBorder(color.opacity(0.13), lineWidth: 1)
            }
    }
}

private struct HealthBadge: View {
    let health: ProviderHealth

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(health.shortLabel)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.085), in: Capsule())
    }

    private var color: Color {
        switch health {
        case .live: .green
        case .loading: SettingsPalette.accent
        case .stale: .orange
        case .signedOut, .permissionRequired, .unavailable: Color.red.opacity(0.9)
        }
    }
}

private extension View {
    func settingsCard() -> some View {
        // The shadow sits on the background shape, not on the whole card: shadowing the card
        // rasterizes all of its content offscreen (~40 MB per card at Retina scale).
        background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(SettingsPalette.card)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(SettingsPalette.cardStroke, lineWidth: 1)
        }
    }
}
