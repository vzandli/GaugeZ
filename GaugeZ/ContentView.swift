import SwiftUI

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case providers = "Providers"
    case appearance = "Appearance"
    case diagnostics = "Diagnostics"
    case updates = "Updates"

    var id: String { rawValue }

    var symbol: String {
        switch self {
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
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 640)
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

            Text("GENERAL")
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
                    VStack(alignment: .trailing, spacing: 4) {
                    ProviderSettingsRow(
                        provider: provider,
                        snapshot: store.snapshot(for: provider),
                        enabled: Binding(
                            get: { store.enabledProviders.contains(provider) },
                            set: { store.setProvider(provider, enabled: $0) }
                        ),
                        claudeSource: $store.claudeSource,
                        openProvider: { store.open(provider) }
                    )
                    HStack(spacing: 8) {
                        Button { store.moveProvider(provider, by: -1) } label: { Label("Up", systemImage: "arrow.up") }
                            .disabled(store.providerOrder.first == provider)
                            .accessibilityLabel("Move \(provider.displayName) up in the rail")
                        Button { store.moveProvider(provider, by: 1) } label: { Label("Down", systemImage: "arrow.down") }
                            .disabled(store.providerOrder.last == provider)
                            .accessibilityLabel("Move \(provider.displayName) down in the rail")
                    }
                    .font(.caption).buttonStyle(.borderless)
                    }
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
    @Binding var claudeSource: ClaudeSource
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
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primary)
                    .lineLimit(1)
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

    private var statusTitle: String {
        guard enabled else { return "Not shown in rail" }
        if let remaining = snapshot.remainingPercent {
            return "\(remaining)% remaining"
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

private struct AppearanceSettingsPage: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        SettingsPageContainer {
            SettingsPageHeader(
                eyebrow: "PERSONALIZATION",
                title: "Appearance",
                subtitle: "Tune how GaugeZ looks and behaves at the edge of your screen."
            )

            VStack(spacing: 0) {
                    SettingsControlRow(title: "Launch at login", subtitle: "Keep GaugeZ available after signing in") {
                        Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                            .labelsHidden().toggleStyle(SettingsPalette.toggle)
                    }
                    if let problem = store.loginProblem {
                        Text(problem).font(.caption).foregroundStyle(.orange).padding(12)
                    }
                    SettingsRowDivider()
                    SettingsControlRow(title: "Session activity", subtitle: "Show Claude Code session states from local metadata") {
                        Toggle("Show session activity", isOn: $store.activityEnabled).labelsHidden().toggleStyle(SettingsPalette.toggle)
                    }
                    SettingsRowDivider()
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
                    SettingsControlRow(
                        title: "Rail visibility",
                        subtitle: "When the edge rail appears"
                    ) {
                        Picker("Rail visibility", selection: $store.displayMode) {
                            ForEach(DisplayMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 152)
                    }

                    SettingsRowDivider()

                    SettingsControlRow(
                        title: "Screen edge",
                        subtitle: "Anchor GaugeZ to any screen edge"
                    ) {
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
                            Slider(
                                value: $store.verticalPosition,
                                in: 0...1
                            )
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

                    SettingsRowDivider()

                    SettingsControlRow(
                        title: "Surface",
                        subtitle: "Choose the rail material"
                    ) {
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
            .frame(maxWidth: .infinity)
            .settingsCard()
        }
    }

    private var transparencyPercent: Int {
        Int(round((1.0 - store.glassOpacity) * 100))
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

    private let columns = [
        GridItem(.adaptive(minimum: 245, maximum: 360), spacing: 14, alignment: .top)
    ]

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

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(store.connectedProviders) { provider in
                    DiagnosticsCard(snapshot: store.snapshot(for: provider))
                }
            }

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

private struct DiagnosticsCard: View {
    @EnvironmentObject private var store: UsageStore
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderLogo(provider: snapshot.provider, size: 18)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(snapshot.provider.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsPalette.primary)
                Spacer()
                HealthBadge(health: snapshot.health)
            }

            VStack(spacing: 9) {
                DiagnosticValue(label: "Source", value: snapshot.source)
                if let retry = store.nextRetry(for: snapshot.provider) {
                    DiagnosticValue(label: "Next retry", value: retry.formatted(date: .omitted, time: .standard))
                }
                if let window = snapshot.headlineWindow {
                    DiagnosticValue(label: "Rail window", value: window.label)
                }
                if let plan = snapshot.planName {
                    DiagnosticValue(label: "Plan", value: plan)
                }
                DiagnosticValue(
                    label: "Observed",
                    value: snapshot.observedAt.formatted(date: .abbreviated, time: .shortened)
                )
            }

            if let error = store.actionErrors[snapshot.provider] {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let message = snapshot.health.message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Retry") { store.refresh(snapshot.provider) }
                    .disabled(!store.enabledProviders.contains(snapshot.provider) || store.refreshing.contains(snapshot.provider) || store.nextRetry(for: snapshot.provider) != nil)
                Button("Open app") { store.open(snapshot.provider) }
                Spacer()
                Button("Forget reading") { store.forget(snapshot.provider) }
                    .help("Clears GaugeZ’s cached reading. The enabled provider can refresh again later.")
            }
            .font(.caption).buttonStyle(.borderless)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .settingsCard()
    }
}

private struct DiagnosticValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(SettingsPalette.tertiary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(SettingsPalette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
        .font(.system(size: 10.5))
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
