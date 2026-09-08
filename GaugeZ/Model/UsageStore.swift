import AppKit
import Combine
import Foundation
import os
import SwiftUI
import ServiceManagement
import Network
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    let isPreview = ProcessInfo.processInfo.environment["GAUGEZ_PREVIEW_DATA"] == "1"
    @Published private(set) var snapshots: [ProviderID: UsageSnapshot]
    @Published var enabledProviders: Set<ProviderID> {
        didSet { persistEnabledProviders() }
    }
    @Published var displayMode: DisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: Keys.displayMode) }
    }
    @Published var edgeSide: EdgeSide {
        didSet { UserDefaults.standard.set(edgeSide.rawValue, forKey: Keys.edgeSide) }
    }
    /// Dock tile, menu bar item, or neither. The app delegate applies it.
    @Published var appPresence: AppPresence {
        didSet { UserDefaults.standard.set(appPresence.rawValue, forKey: Keys.appPresence) }
    }
    /// Liquid Glass surfaces instead of solid black.
    @Published var glassEnabled: Bool {
        didSet { UserDefaults.standard.set(glassEnabled, forKey: Keys.glassEnabled) }
    }
    /// Opacity of the Liquid Glass surfaces (0.15 = very transparent, 0.85 = dark tinted).
    @Published var glassOpacity: Double {
        didSet { UserDefaults.standard.set(glassOpacity, forKey: Keys.glassOpacity) }
    }
    /// Which Claude source to read. Choosing the CLI is the user's consent for Keychain access.
    @Published var claudeSource: ClaudeSource {
        didSet {
            UserDefaults.standard.set(claudeSource.rawValue, forKey: Keys.claudeSource)
            if oldValue != claudeSource {
                invalidate(.claude)
                refresh(.claude)
            }
        }
    }
    /// Primary color for the collapsed edge rail git commit indicator dots.
    @Published var indicatorColorHex: String {
        didSet { UserDefaults.standard.set(indicatorColorHex, forKey: Keys.indicatorColorHex) }
    }
    /// Normalized vertical position along the screen edge (0.0 = bottom, 0.5 = middle, 1.0 = top).
    @Published var verticalPosition: Double {
        didSet {
            let clamped = max(0.0, min(1.0, verticalPosition))
            if clamped != verticalPosition {
                verticalPosition = clamped
            } else {
                UserDefaults.standard.set(clamped, forKey: Keys.verticalPosition)
            }
        }
    }

    /// Scale factor for the meter notch (0.70 = compact, 1.0 = default, 1.40 = spacious).
    @Published var railScale: Double {
        didSet {
            let rounded = (railScale * 100).rounded() / 100
            let clamped = max(0.70, min(1.40, rounded))
            if clamped != railScale {
                railScale = clamped
            } else {
                UserDefaults.standard.set(clamped, forKey: Keys.railScale)
            }
        }
    }

    func resetRailScale() {
        railScale = 1.0
    }

    @Published var selectedDisplayID: String = UserDefaults.standard.string(forKey: "selectedDisplayID") ?? "main" {
        didSet { UserDefaults.standard.set(selectedDisplayID, forKey: "selectedDisplayID") }
    }
    @Published var providerOrder: [ProviderID] = [] {
        didSet { UserDefaults.standard.set(providerOrder.map(\.rawValue), forKey: "providerOrder") }
    }
    @Published var headlineWindows: [String: String] = UserDefaults.standard.dictionary(forKey: "headlineWindows") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(headlineWindows, forKey: "headlineWindows") }
    }
    @Published var activityEnabled = UserDefaults.standard.object(forKey: "activityEnabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(activityEnabled, forKey: "activityEnabled")
            configureActivity()
        }
    }
    @Published var mutedAlertProviders = Set(UserDefaults.standard.stringArray(forKey: "mutedAlertProviders") ?? []) {
        didSet { UserDefaults.standard.set(Array(mutedAlertProviders), forKey: "mutedAlertProviders") }
    }
    @Published var sessionPeekEnabled = UserDefaults.standard.object(forKey: "sessionPeekEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sessionPeekEnabled, forKey: "sessionPeekEnabled") }
    }
    @Published var sessionChimeEnabled = UserDefaults.standard.object(forKey: "sessionChimeEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(sessionChimeEnabled, forKey: "sessionChimeEnabled") }
    }
    /// System sound names for each session event; see `SessionChime.systemSounds`.
    @Published var finishedChime = UserDefaults.standard.string(forKey: "sessionChimeFinished") ?? SessionChime.defaultFinished {
        didSet { UserDefaults.standard.set(finishedChime, forKey: "sessionChimeFinished") }
    }
    @Published var waitingChime = UserDefaults.standard.string(forKey: "sessionChimeWaiting") ?? SessionChime.defaultWaiting {
        didSet { UserDefaults.standard.set(waitingChime, forKey: "sessionChimeWaiting") }
    }

    func chime(for reason: SessionCompletionWatcher.Reason) -> String {
        reason == .finished ? finishedChime : waitingChime
    }

    /// Plays the chosen sound for `reason` so the user can hear their pick in Settings.
    func previewChime(_ reason: SessionCompletionWatcher.Reason) {
        SessionChime.play(named: chime(for: reason))
    }
    @Published private(set) var completionPeek: SessionCompletionWatcher.Event?
    private var completionPeekTask: Task<Void, Never>?
    private var isErasing = false
    let sessionCompletions = PassthroughSubject<SessionCompletionWatcher.Event, Never>()
    private var completionWatcher = SessionCompletionWatcher()
    private var thresholdNotifier = ThresholdNotifier()
    @Published private(set) var sessions: [ActivitySession] = []
    @Published private(set) var refreshing: Set<ProviderID> = []
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginProblem: String?
    @Published private(set) var actionErrors: [ProviderID: String] = [:]
    @Published private(set) var availableDisplays: [DisplayChoice] = DisplayChoice.current()
    @Published private(set) var clock = Date()
    var expandedPanels: Set<UUID> = []
    var railIsExpanded: Bool { !expandedPanels.isEmpty }
    private var activityTask: Task<Void, Never>?
    private let activityReader = ActivityReader()
    private let networkMonitor = NWPathMonitor()
    private var nextAutomaticRefresh: [ProviderID: Date] = [:]
    private var lastRefreshSucceeded: [ProviderID: Date] = [:]
    private var refreshGenerations: [ProviderID: UUID] = [:]
    private var delayedRefreshes: [ProviderID: Task<Void, Never>] = [:]

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginProblem = SMAppService.mainApp.status == .requiresApproval
                ? "Allow GaugeZ in System Settings → General → Login Items." : nil
        } catch {
            loginProblem = "macOS could not update the login item. Move GaugeZ to Applications and try again."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Stops writers before clearing GaugeZ-owned state. Provider credentials belong to their apps.
    func eraseAllDataAndQuit() async throws {
        guard !isErasing else { return }
        isErasing = true
        defer { isErasing = false }
        do { try await eraseData() }
        catch {
            startPeriodicRefresh()
            configureActivity()
            throw error
        }
    }

    private func eraseData() async throws {
        if SMAppService.mainApp.status == .enabled { try await SMAppService.mainApp.unregister() }
        periodicTask?.cancel()
        activityTask?.cancel()
        completionPeekTask?.cancel()
        ThresholdAlerts.shared.cancel()
        for task in refreshTasks.values { task.cancel() }
        for task in delayedRefreshes.values { task.cancel() }
        for adapter in providers.values { adapter.forgetCredentials() }
        for task in refreshTasks.values { await task.value }
        try SnapshotCache.erase()
        URLCache.shared.removeAllCachedResponses()
        let fm = FileManager.default
        if let bundleID = Bundle.main.bundleIdentifier {
            for directory in [fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(bundleID),
                              fm.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Saved Application State/" + bundleID + ".savedState")] {
                if let directory, fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            }
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        NSApp.terminate(nil)
    }

    func updateSystemSettings() {
        availableDisplays = DisplayChoice.current()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func moveProvider(_ provider: ProviderID, by offset: Int) {
        guard let index = providerOrder.firstIndex(of: provider), providerOrder.indices.contains(index + offset) else { return }
        providerOrder.swapAt(index, index + offset)
    }

    func nextRetry(for provider: ProviderID) -> Date? { ProviderRetryPolicy(provider: provider).deadline }

    func activity(for provider: ProviderID) -> [ActivitySession] {
        activityEnabled && enabledProviders.contains(provider) ? sessions.filter { $0.provider == provider } : []
    }

    private func configureActivity() {
        activityTask?.cancel()
        sessions = []
        completionWatcher = SessionCompletionWatcher()
        completionPeekTask?.cancel()
        completionPeek = nil
        guard !isPreview, activityEnabled, enabledProviders.contains(where: \.supportsActivity) else { return }
        activityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let reader = self?.activityReader else { return }
                let enabled = self?.visibleProviders ?? []
                var found: [ActivitySession] = []
                for provider in enabled where provider.kind == .claude {
                    found += await reader.readClaudeSessions(profile: ClaudeProfile(provider: provider))
                }
                if enabled.contains(.cursor) {
                    let app = NSWorkspace.shared.runningApplications.first {
                        $0.bundleIdentifier == "com.todesktop.230313mzl4w4u92" || $0.bundleURL?.lastPathComponent == "Cursor.app"
                    }
                    let launchedAt = app.map { $0.launchDate ?? .distantPast }
                    found += await reader.readCursorSessions(launchedAt: launchedAt, includeIdle: true)
                }
                // Codex and Antigravity are inferred from write recency: an eight-second pause is
                // a think, not a finish, so they never become idle and never announce completion.
                if enabled.contains(.codex) {
                    found += await reader.readCodexSessions()
                }
                if enabled.contains(.antigravity) {
                    found += await reader.readAntigravitySessions()
                }
                if enabled.contains(.grok) {
                    found += await reader.readGrokSessions()
                }
                found = ActivityReader.prioritized(found)
                guard !Task.isCancelled else { return }
                if let self {
                    let events = self.completionWatcher.absorb(found)
                    if let event = events.first {
                        if self.sessionChimeEnabled { SessionChime.play(named: self.chime(for: event.reason)) }
                        if self.sessionPeekEnabled {
                            self.completionPeek = event
                            self.sessionCompletions.send(event)
                            self.completionPeekTask?.cancel()
                            self.completionPeekTask = Task { [weak self] in
                                try? await Task.sleep(for: .seconds(5))
                                guard !Task.isCancelled else { return }
                                self?.completionPeek = nil
                            }
                        }
                    }
                    // Idle Cursor chats exist only so the watcher can see a run end; the card
                    // keeps showing working and waiting chats, as it always has.
                    let shown = found.filter { !($0.provider == .cursor && $0.state == .idle) }
                    if self.sessions != shown { self.sessions = shown }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Explicit retry can ask for Keychain permission again; automatic polling never clears a refusal.
    func retry(_ provider: ProviderID) {
        providers[provider]?.forgetCredentials()
        refresh(provider)
    }

    func forget(_ provider: ProviderID) {
        invalidate(provider)
    }

    private func invalidate(_ provider: ProviderID) {
        refreshTasks[provider]?.cancel()
        refreshTasks[provider] = nil
        delayedRefreshes[provider]?.cancel()
        delayedRefreshes[provider] = nil
        refreshGenerations[provider] = nil
        refreshing.remove(provider)
        ProviderRetryPolicy(provider: provider).reset()
        providers[provider]?.forgetCredentials()
        snapshots[provider] = .placeholder(for: provider)
        actionErrors[provider] = nil
        // The next reading after a forget or re-enable is a fresh fact, so it may alert again.
        thresholdNotifier.forget(provider)
        SnapshotCache.save(Array(snapshots.values))
    }

    var indicatorVariants: [Color] {
        Color.indicatorVariants(fromHex: indicatorColorHex)
    }

    private var providers: [ProviderID: any UsageProviding] = [:]
    private var refreshTasks: [ProviderID: Task<Void, Never>] = [:]
    private var periodicTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var applicationObservers: [NSObjectProtocol] = []
    private var lastRefreshStarted: [ProviderID: Date] = [:]

    /// Bundle identifiers whose launch, activation, or exit should refresh a provider.
    nonisolated private static let applicationBundles: [String: ProviderID] = [
        "com.anthropic.claudefordesktop": .claude,
        "com.todesktop.230313mzl4w4u92": .cursor,
        "com.openai.chat": .codex,
        "com.openai.codex": .codex,
        "com.google.antigravity": .antigravity,
        "com.google.antigravity-ide": .antigravity
    ]

    /// Error descriptions never contain tokens, account IDs, or response bodies.
    private static let log = Logger(subsystem: "com.vzyork.GaugeZ", category: "usage")
    /// Optional plain-text mirror of the log lines, enabled by GAUGEZ_DEBUG_LOG=<file path>.
    private static let debugLogURL = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_LOG"].map(URL.init(fileURLWithPath:))

    private static func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
        DebugLog.write(message)
    }

    init() {
        let previewCount = min(20, max(1, Int(ProcessInfo.processInfo.environment["GAUGEZ_PREVIEW_PROFILES"] ?? "2") ?? 2))
        let profiles = isPreview
            ? [ClaudeProfile()] + (1..<previewCount).map { index in
                ClaudeProfile(provider: ProviderID(rawValue: index == 1 ? "claude-work" : "claude-profile-\(index)")!)
            }
            : ClaudeProfile.discover()
        let available = profiles.map(\.provider) + ProviderID.allCases.filter { $0 != .claude }
        snapshots = Dictionary(
            uniqueKeysWithValues: available.map { provider in
                (provider, .placeholder(for: provider))
            }
        )

        let savedOrder = (UserDefaults.standard.stringArray(forKey: "providerOrder") ?? []).compactMap(ProviderID.init(rawValue:))
        var seen: Set<ProviderID> = []
        providerOrder = (savedOrder.filter(available.contains) + available).filter { seen.insert($0).inserted }
        if let stored = UserDefaults.standard.stringArray(forKey: Keys.enabledProviders) {
            enabledProviders = Set(stored.compactMap(ProviderID.init(rawValue:))).intersection(available)
            // Existing switches stay off. Newly discovered accounts/providers start disabled until enabled.
        } else {
            enabledProviders = Set(available)
        }
        providers = [.codex: CodexUsageProvider(), .cursor: CursorUsageProvider(),
                     .antigravity: AntigravityUsageProvider(), .glm: GLMUsageProvider(), .grok: GrokUsageProvider(),
                     .opencode: OpenCodeUsageProvider(), .copilot: GitHubCopilotProvider()]
        for profile in profiles {
            providers[profile.provider] = ClaudeUsageProvider(profile: profile, selectedSource: {
                ClaudeSource(rawValue: UserDefaults.standard.string(forKey: Keys.claudeSource) ?? "") ?? .desktop
            })
        }

        displayMode = DisplayMode(
            rawValue: UserDefaults.standard.string(forKey: Keys.displayMode) ?? ""
        ) ?? .hover
        edgeSide = EdgeSide(
            rawValue: UserDefaults.standard.string(forKey: Keys.edgeSide) ?? ""
        ) ?? .right
        appPresence = AppPresence(
            rawValue: UserDefaults.standard.string(forKey: Keys.appPresence) ?? ""
        ) ?? .menuBar
        claudeSource = ClaudeSource(
            rawValue: UserDefaults.standard.string(forKey: Keys.claudeSource) ?? ""
        ) ?? .desktop
        glassEnabled = UserDefaults.standard.object(forKey: Keys.glassEnabled) as? Bool ?? true
        let savedOpacity = UserDefaults.standard.object(forKey: Keys.glassOpacity) as? Double ?? 0.50
        glassOpacity = max(0.0, min(1.0, savedOpacity))
        indicatorColorHex = UserDefaults.standard.string(forKey: Keys.indicatorColorHex) ?? "#407CDE"
        let savedVertical = UserDefaults.standard.object(forKey: Keys.verticalPosition) as? Double ?? 0.5
        verticalPosition = max(0.0, min(1.0, savedVertical))
        let savedScale = UserDefaults.standard.object(forKey: Keys.railScale) as? Double ?? 1.0
        railScale = max(0.70, min(1.40, savedScale))
        if let forced = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_GLASS"] {
            glassEnabled = forced == "1"   // debug aid; not persisted
        }
        if let forced = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_EDGE"], let side = EdgeSide(rawValue: forced) {
            edgeSide = side   // debug aid; not persisted because observers do not fire in init
        }

        if isPreview {
            enabledProviders = Set(available)
            providerOrder = available
            headlineWindows = [:]
            displayMode = .hover
            activityEnabled = true
            sessions = [ActivitySession(id: "preview", provider: .claude, name: "GaugeZ", project: "GaugeZ",
                                        state: .waiting, waitingReason: "Review the proposed changes",
                                        since: Date().addingTimeInterval(-6 * 60)),
                        ActivitySession(id: "preview-cursor", provider: .cursor, name: "Build usage dashboard", project: "GaugeZ",
                                        state: .working, waitingReason: nil, since: Date().addingTimeInterval(-90)),
                        ActivitySession(id: "preview-codex", provider: .codex, name: "Codex", project: "Codex",
                                        state: .working, waitingReason: nil, since: Date(), isInferred: true)]
            snapshots = Dictionary(uniqueKeysWithValues: available.enumerated().map { index, provider in
                (provider, UsageSnapshot(provider: provider, accountID: nil, planName: "Preview plan",
                    windows: [
                        UsageWindow(id: "session", label: "5-hour limit", usedPercent: provider == .copilot ? 99.7 : index == 2 ? 100 : Double((20 + index * 15) % 100),
                                    resetsAt: Date().addingTimeInterval(3600), durationMinutes: 300),
                        UsageWindow(id: "weekly", label: "Weekly limit", usedPercent: 35,
                                    resetsAt: Date().addingTimeInterval(172800), durationMinutes: 10080)
                    ], observedAt: .now, source: "Preview data", health: .live))
            })
            return
        }

        // Last known values from the previous run, shown as stale until a refresh succeeds.
        for cached in SnapshotCache.load() where enabledProviders.contains(cached.provider) {
            snapshots[cached.provider] = cached
        }
        SnapshotCache.save(Array(snapshots.values))

        startPeriodicRefresh()
        observeWake()
        observeApplications()
        configureActivity()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in self?.refresh() }
        }
        networkMonitor.start(queue: DispatchQueue(label: "GaugeZ.network"))
    }

    deinit {
        periodicTask?.cancel()
        activityTask?.cancel()
        networkMonitor.cancel()
        for task in delayedRefreshes.values { task.cancel() }
        for task in refreshTasks.values {
            task.cancel()
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        for observer in applicationObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var visibleProviders: [ProviderID] {
        providerOrder.filter(enabledProviders.contains)
    }

    @Published var railPage = 0

    var railPageCapacity: Int {
        let screen = selectedDisplayID == "all" ? NSScreen.screens.min {
            (edgeSide.isHorizontal ? $0.visibleFrame.width : $0.visibleFrame.height) < (edgeSide.isHorizontal ? $1.visibleFrame.width : $1.visibleFrame.height)
        } : NSScreen.screens.first { DisplayChoice.identifier(for: $0) == selectedDisplayID } ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let length = (edgeSide.isHorizontal ? frame.width : frame.height) - 24
        let scale = CGFloat(railScale)
        let rowHeight = RailMetrics.rowHeight(scale: scale)
        let rowSpacing = RailMetrics.rowSpacing(scale: scale)
        let fixed = RailMetrics.shapeHeight(providerCount: 1, scale: scale) - rowHeight
        return max(1, Int((length - fixed + rowSpacing) / (rowHeight + rowSpacing)))
    }

    var railPageCount: Int { max(1, (visibleProviders.count + railPageCapacity - 1) / railPageCapacity) }
    var currentRailPage: Int { min(max(0, railPage), railPageCount - 1) }
    var railProviders: [ProviderID] {
        Array(visibleProviders.dropFirst(currentRailPage * railPageCapacity).prefix(railPageCapacity))
    }

    /// Providers that have a working adapter behind them.
    var connectedProviders: [ProviderID] {
        providerOrder.filter { providers[$0] != nil }
    }

    func snapshot(for provider: ProviderID) -> UsageSnapshot {
        var value = snapshots[provider] ?? .placeholder(for: provider)
        value.headlineWindowID = headlineWindows[provider.rawValue] ?? value.headlineWindowID
        return value
    }

    func setProvider(_ provider: ProviderID, enabled: Bool) {
        if enabled {
            enabledProviders.insert(provider)
            DispatchQueue.main.async { [weak self] in
                self?.refresh(provider)
            }
        } else {
            enabledProviders.remove(provider)
            invalidate(provider)
        }
        configureActivity()
    }

    /// The other Claude source, offered when the selected one cannot produce a value.
    func alternativeClaudeSource(for snapshot: UsageSnapshot) -> ClaudeSource? {
        guard snapshot.provider == .claude else { return nil }
        switch snapshot.health {
        case .permissionRequired, .signedOut, .unavailable:
            return claudeSource == .desktop ? .claudeCode : .desktop
        default:
            return nil
        }
    }

    func refresh() {
        for provider in visibleProviders {
            refresh(provider)
        }
    }

    func refresh(_ provider: ProviderID) {
        guard !isErasing, !isPreview, let adapter = providers[provider], enabledProviders.contains(provider), refreshTasks[provider] == nil else { return }
        // A backoff deadline only matters when a network fetch is the sole source of data:
        // the provider itself declines the request, and a source with a local fallback
        // (e.g. the Claude Desktop usage log) can still return a reading.
        let generation = UUID()
        refreshGenerations[provider] = generation
        lastRefreshStarted[provider] = .now
        nextAutomaticRefresh[provider] = Date().addingTimeInterval(60 + Double.random(in: 0...10))
        refreshing.insert(provider)
        refreshTasks[provider] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.refreshGenerations[provider] == generation {
                    self.refreshTasks[provider] = nil
                    self.refreshing.remove(provider)
                }
            }
            await self.refresh(provider, using: adapter)
        }
    }

    private func refresh(_ provider: ProviderID, after delay: Duration) {
        delayedRefreshes[provider]?.cancel()
        delayedRefreshes[provider] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh(provider)
        }
    }

    /// The Claude usage endpoint rate-limits polling faster than every few minutes, so Claude
    /// never inherits the 60 s "active" cadence the local providers can afford.
    private func refreshIfIdle(_ provider: ProviderID, for interval: TimeInterval) {
        let last = lastRefreshStarted[provider] ?? .distantPast
        let floor: TimeInterval = (provider.kind == .claude || provider.kind == .grok) ? 300 : 0
        guard Date().timeIntervalSince(last) >= max(interval, floor) else { return }
        refresh(provider)
    }

    func open(_ provider: ProviderID) {
        actionErrors[provider] = nil
        if provider.kind == .grok {
            switch GrokInstallation.openInTerminal() {
            case .opened: return
            case .failed(let message):
                actionErrors[provider] = message
                return
            case .notInstalled: break
            }
        }
        guard let url = provider.applicationURL else { return }
        if !url.isFileURL {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                self?.actionErrors[provider] = "The provider app could not be opened. Install it in Applications and try again."
            }
        }
    }

    private func refresh(_ provider: ProviderID, using adapter: any UsageProviding) async {
        let previous = snapshot(for: provider)
        snapshots[provider] = previous.windows.isEmpty
            ? .placeholder(for: provider, health: .loading)
            : previous

        do {
            let snapshot = try await adapter.fetchSnapshot()
            guard !Task.isCancelled else { return }
            Self.note("\(provider.displayName) refreshed: \(snapshot.health.shortLabel), \(snapshot.windows.count) windows via \(snapshot.source)")
            lastRefreshSucceeded[provider] = .now
            if snapshot.derivedRequestCount != nil, !previous.windows.isEmpty {
                snapshots[provider] = previous.withHealth(.stale("Quota unavailable. Derived locally: \(snapshot.derivedRequestCount!) model turns today."))
            } else {
                snapshots[provider] = snapshot
            }
            let alerts = thresholdNotifier.observe(self.snapshot(for: provider), muted: mutedAlertProviders.contains(provider.rawValue))
            ThresholdAlerts.shared.deliver(alerts)
            SnapshotCache.save(Array(snapshots.values))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            Self.note("\(provider.displayName) refresh failed: \(error.localizedDescription)")
            snapshots[provider] = Self.failedSnapshot(for: provider, previous: previous, error: error)
            SnapshotCache.save(Array(snapshots.values))
        }
    }

    /// Keeps the last valid values when the provider is merely unreachable (stale or unavailable)
    /// or when a Keychain read was refused (the account has not changed, only our access to it),
    /// and clears them when the sign-in itself is the problem, so a signed-out provider never
    /// looks like a reading.
    private static func failedSnapshot(
        for provider: ProviderID,
        previous: UsageSnapshot,
        error: Error
    ) -> UsageSnapshot {
        // A rate-limit backoff is not news about the reading itself: keep the last good values
        // untouched (the periodic tick ages them normally) and only surface the notice when
        // there is nothing else to show.
        if error is ProviderRetryError, !previous.windows.isEmpty {
            return previous
        }
        let health: ProviderHealth
        if let described = error as? ProviderHealthDescribing {
            health = described.providerHealth
        } else if !previous.windows.isEmpty {
            health = .stale(error.localizedDescription)
        } else {
            health = .unavailable(error.localizedDescription)
        }

        switch health {
        case .stale, .unavailable, .permissionRequired:
            if !previous.windows.isEmpty {
                return previous.withHealth(health)
            }
            if case .stale(let message) = health {
                return .placeholder(for: provider, health: .unavailable(message))
            }
            return .placeholder(for: provider, health: health)
        default:
            return .placeholder(for: provider, health: health)
        }
    }

    private func startPeriodicRefresh() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.automaticRefreshTick()
            }
        }
    }

    private func automaticRefreshTick() {
        clock = .now
        for provider in visibleProviders {
            let previous = snapshot(for: provider)
            let crossedReset = previous.windows.contains { window in
                guard let reset = window.resetsAt else { return false }
                return previous.observedAt < reset && reset <= clock
            }
            // Age is measured from the store's last successful fetch, not the reading's own
            // timestamp: a source that reports an older sample (Claude Desktop logs every 15 min)
            // is still current as long as it keeps being re-read.
            let lastFetched = max(previous.observedAt, lastRefreshSucceeded[provider] ?? .distantPast)
            if previous.health == .live, clock.timeIntervalSince(lastFetched) > 360 || crossedReset {
                snapshots[provider] = previous.withHealth(.stale(crossedReset
                    ? "A reset time has passed. Awaiting a fresh reading."
                    : "This reading is over six minutes old."))
            }
            let active = railIsExpanded || activity(for: provider).contains { $0.state == .working || $0.state == .waiting }
            let interval: TimeInterval = active ? 60 : 300
            if clock >= (nextAutomaticRefresh[provider] ?? .distantPast) {
                refreshIfIdle(provider, for: crossedReset ? 60 : interval)
            }
        }
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
    }

    /// A provider's own app starting, coming to the front, or quitting is the best moment to
    /// re-read it: the value it shows should match what the user just saw in that app.
    private func observeApplications() {
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, (ProviderID) -> Void)] = [
            (NSWorkspace.didLaunchApplicationNotification, { [weak self] provider in
                self?.refresh(provider, after: .seconds(8))
            }),
            (NSWorkspace.didActivateApplicationNotification, { [weak self] provider in
                self?.refreshIfIdle(provider, for: 60)
            }),
            (NSWorkspace.didTerminateApplicationNotification, { [weak self] provider in
                self?.refresh(provider, after: .seconds(1))
            })
        ]
        for (name, action) in pairs {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    let bundleID = app.bundleIdentifier,
                    let provider = Self.applicationBundles[bundleID]
                else { return }
                Task { @MainActor in action(provider) }
            }
            applicationObservers.append(observer)
        }
    }

    private func persistEnabledProviders() {
        let rawValues = enabledProviders.map(\.rawValue).sorted()
        UserDefaults.standard.set(rawValues, forKey: Keys.enabledProviders)
    }

    private enum Keys {
        static let enabledProviders = "enabledProviders"
        static let displayMode = "displayMode"
        static let edgeSide = "edgeSide"
        static let appPresence = "appPresence"
        static let claudeSource = "claudeSource"
        static let glassEnabled = "glassEnabled"
        static let glassOpacity = "glassOpacity"
        static let indicatorColorHex = "indicatorColorHex"
        static let verticalPosition = "verticalPosition"
        static let railScale = "railScale"
    }
}

// MARK: - Last-known snapshot cache

/// Persists the last valid windows per provider so the rail can show last-known values when a
/// provider app is closed or offline. Stores no credentials, account identifiers, or raw responses.
enum SnapshotCache {
    private struct Entry: Codable {
        let provider: ProviderID
        let planName: String?
        let windows: [UsageWindow]
        let observedAt: Date
        let source: String
        let costInfo: ProviderCostInfo?
        let headlineWindowID: String?

        init(provider: ProviderID, planName: String?, windows: [UsageWindow], observedAt: Date, source: String, costInfo: ProviderCostInfo? = nil, headlineWindowID: String? = nil) {
            self.provider = provider
            self.planName = planName
            self.windows = windows
            self.observedAt = observedAt
            self.source = source
            self.costInfo = costInfo
            self.headlineWindowID = headlineWindowID
        }
    }

    static let staleMessage = "Showing the last known values. Refresh to update."

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GaugeZ", isDirectory: true).appendingPathComponent("last-snapshots.json")
    }

    static func erase() throws {
        let directory = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    static func load() -> [UsageSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries.filter { !$0.windows.isEmpty }.map { entry in
            UsageSnapshot(
                provider: entry.provider,
                accountID: nil,
                planName: entry.planName,
                windows: entry.windows,
                observedAt: entry.observedAt,
                source: entry.source,
                health: .stale(staleMessage),
                costInfo: entry.costInfo, headlineWindowID: entry.headlineWindowID
            )
        }
    }

    static func save(_ snapshots: [UsageSnapshot]) {
        let entries = snapshots
            .filter { !$0.windows.isEmpty }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
            .map { Entry(provider: $0.provider, planName: $0.planName, windows: $0.windows, observedAt: $0.observedAt, source: $0.source, costInfo: $0.costInfo, headlineWindowID: $0.headlineWindowID) }
        do {
            let url = fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            // Losing the cache only costs the next launch its last-known values.
        }
    }
}

/// Debug aid: GAUGEZ_DEBUG_LOG=<file> mirrors diagnostic lines to a file. No-op otherwise.
enum DebugLog {
    private static let url = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_LOG"].map(URL.init(fileURLWithPath:))

    static func write(_ message: String) {
        guard let url else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

// MARK: - Color Hex & Indicator Variants

extension Color {
    init?(hex: String) {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if clean.hasPrefix("#") { clean.removeFirst() }
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }

    var hexString: String {
        NSColor(self).hexString
    }

    /// Generates 5 distinct, harmonious variants for the edge rail git-commit squares.
    /// Supports chromatic colors as well as Black and White monochrome themes.
    static func indicatorVariants(fromHex hex: String) -> [Color] {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let baseColor: NSColor
        if clean == "#FFFFFF" || clean == "FFFFFF" {
            baseColor = .white
        } else if clean == "#000000" || clean == "000000" || clean == "#18181B" || clean == "#1F2328" {
            baseColor = .black
        } else {
            var c = clean
            if c.hasPrefix("#") { c.removeFirst() }
            if let rgb = UInt64(c, radix: 16), c.count == 6 {
                baseColor = NSColor(
                    red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                    green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                    blue: CGFloat(rgb & 0xFF) / 255.0,
                    alpha: 1.0
                )
            } else {
                baseColor = NSColor(red: 0.251, green: 0.486, blue: 0.871, alpha: 1.0)
            }
        }

        guard let srgb = baseColor.usingColorSpace(.sRGB) else {
            return [
                Color(red: 0.596, green: 0.725, blue: 0.941),
                Color(red: 0.251, green: 0.486, blue: 0.871),
                Color(red: 0.525, green: 0.675, blue: 0.918),
                Color(red: 0.184, green: 0.435, blue: 0.847),
                Color(red: 0.388, green: 0.580, blue: 0.894)
            ]
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Monochrome handling for White, Gray, and Black
        if s < 0.08 {
            if b > 0.6 {
                // White / silver variants: pure white and light metallic grays
                let grays: [Double] = [1.0, 0.80, 0.93, 0.70, 0.86]
                return grays.map { Color(white: $0) }
            } else {
                // Black / charcoal variants: distinct dark graphite and slate tones
                let grays: [Double] = [0.65, 0.35, 0.52, 0.25, 0.44]
                return grays.map { Color(white: $0) }
            }
        }

        let baseS = max(0.40, min(1.0, s))
        let baseB = max(0.70, min(1.0, b))

        let configs: [(sMul: CGFloat, sAdd: CGFloat, bMul: CGFloat, bFloor: CGFloat)] = [
            (0.40, 0.10, 1.15, 0.92), // 1. Soft pastel/light
            (1.00, 0.00, 1.00, 0.85), // 2. Vivid primary
            (0.60, 0.15, 1.08, 0.88), // 3. Light-medium accent
            (1.05, 0.05, 0.78, 0.60), // 4. Rich deep (never black)
            (0.80, 0.10, 0.92, 0.75)  // 5. Medium tone
        ]

        return configs.map { config in
            let varS = max(0.18, min(1.0, baseS * config.sMul + config.sAdd))
            let varB = max(config.bFloor, min(1.0, baseB * config.bMul))
            return Color(hue: Double(h), saturation: Double(varS), brightness: Double(varB))
        }
    }
}

extension NSColor {
    var hexString: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#407CDE" }
        let r = Int(round(max(0, min(1, srgb.redComponent)) * 255))
        let g = Int(round(max(0, min(1, srgb.greenComponent)) * 255))
        let b = Int(round(max(0, min(1, srgb.blueComponent)) * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
