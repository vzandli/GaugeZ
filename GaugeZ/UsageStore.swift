import AppKit
import Combine
import Foundation
import os
import SwiftUI
import ServiceManagement
import Network

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

    @Published var selectedDisplayID: String = UserDefaults.standard.string(forKey: "selectedDisplayID") ?? "main" {
        didSet { UserDefaults.standard.set(selectedDisplayID, forKey: "selectedDisplayID") }
    }
    @Published var providerOrder: [ProviderID] = {
        let saved = (UserDefaults.standard.stringArray(forKey: "providerOrder") ?? []).compactMap(ProviderID.init(rawValue:))
        return ProviderID.allCases.sorted { (saved.firstIndex(of: $0) ?? 99) < (saved.firstIndex(of: $1) ?? 99) }
    }() {
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
    @Published private(set) var sessions: [ActivitySession] = []
    @Published private(set) var refreshing: Set<ProviderID> = []
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginProblem: String?
    @Published private(set) var actionErrors: [ProviderID: String] = [:]
    @Published private(set) var availableDisplays: [DisplayChoice] = DisplayChoice.current()
    @Published private(set) var clock = Date()
    var railIsExpanded = false
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
        guard !isPreview, activityEnabled, enabledProviders.contains(.claude) else { return }
        activityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let reader = self?.activityReader else { return }
                let found = await reader.readClaudeSessions()
                guard !Task.isCancelled else { return }
                if self?.sessions != found { self?.sessions = found }
                try? await Task.sleep(for: .seconds(5))
            }
        }
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
        snapshots[provider] = .placeholder(for: provider)
        actionErrors[provider] = nil
        SnapshotCache.save(Array(snapshots.values))
    }

    var indicatorVariants: [Color] {
        Color.indicatorVariants(fromHex: indicatorColorHex)
    }

    private let providers: [ProviderID: any UsageProviding] = [
        .codex: CodexUsageProvider(),
        .claude: ClaudeUsageProvider(selectedSource: {
            ClaudeSource(rawValue: UserDefaults.standard.string(forKey: Keys.claudeSource) ?? "") ?? .desktop
        }),
        .cursor: CursorUsageProvider(),
        .antigravity: AntigravityUsageProvider()
    ]
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
        snapshots = Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.map { provider in
                (provider, .placeholder(for: provider))
            }
        )

        if let stored = UserDefaults.standard.stringArray(forKey: Keys.enabledProviders) {
            enabledProviders = Set(stored.compactMap(ProviderID.init(rawValue:)))
        } else {
            enabledProviders = Set(ProviderID.allCases)
        }

        displayMode = DisplayMode(
            rawValue: UserDefaults.standard.string(forKey: Keys.displayMode) ?? ""
        ) ?? .hover
        edgeSide = EdgeSide(
            rawValue: UserDefaults.standard.string(forKey: Keys.edgeSide) ?? ""
        ) ?? .right
        claudeSource = ClaudeSource(
            rawValue: UserDefaults.standard.string(forKey: Keys.claudeSource) ?? ""
        ) ?? .desktop
        glassEnabled = UserDefaults.standard.object(forKey: Keys.glassEnabled) as? Bool ?? true
        let savedOpacity = UserDefaults.standard.object(forKey: Keys.glassOpacity) as? Double ?? 0.50
        glassOpacity = max(0.0, min(1.0, savedOpacity))
        indicatorColorHex = UserDefaults.standard.string(forKey: Keys.indicatorColorHex) ?? "#407CDE"
        let savedVertical = UserDefaults.standard.object(forKey: Keys.verticalPosition) as? Double ?? 0.5
        verticalPosition = max(0.0, min(1.0, savedVertical))
        if let forced = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_GLASS"] {
            glassEnabled = forced == "1"   // debug aid; not persisted
        }
        if let forced = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_EDGE"], let side = EdgeSide(rawValue: forced) {
            edgeSide = side   // debug aid; not persisted because observers do not fire in init
        }

        if isPreview {
            enabledProviders = Set(ProviderID.allCases)
            providerOrder = ProviderID.allCases
            headlineWindows = [:]
            displayMode = .hover
            activityEnabled = true
            sessions = [ActivitySession(id: "preview", provider: .claude, name: "GaugeZ", project: "GaugeZ",
                                        state: .waiting, waitingReason: "Review the proposed changes")]
            snapshots = Dictionary(uniqueKeysWithValues: ProviderID.allCases.enumerated().map { index, provider in
                (provider, UsageSnapshot(provider: provider, accountID: nil, planName: "Preview plan",
                    windows: [
                        UsageWindow(id: "session", label: "5-hour limit", usedPercent: index == 2 ? 100 : 20 + index * 15,
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

    /// Providers that have a working adapter behind them.
    var connectedProviders: [ProviderID] {
        ProviderID.allCases.filter { providers[$0] != nil }
    }

    func snapshot(for provider: ProviderID) -> UsageSnapshot {
        var value = snapshots[provider] ?? .placeholder(for: provider)
        value.headlineWindowID = headlineWindows[provider.rawValue]
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
        guard !isPreview, let adapter = providers[provider], enabledProviders.contains(provider), refreshTasks[provider] == nil else { return }
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
    private static let minimumPollInterval: [ProviderID: TimeInterval] = [.claude: 300]

    private func refreshIfIdle(_ provider: ProviderID, for interval: TimeInterval) {
        let last = lastRefreshStarted[provider] ?? .distantPast
        let floor = Self.minimumPollInterval[provider] ?? 0
        guard Date().timeIntervalSince(last) >= max(interval, floor) else { return }
        refresh(provider)
    }

    func open(_ provider: ProviderID) {
        guard let url = provider.applicationURL else { return }
        actionErrors[provider] = nil
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
            snapshots[provider] = snapshot
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

    /// Keeps the last valid values when the provider is merely unreachable (stale or unavailable),
    /// and clears them when the sign-in itself is the problem, so a signed-out or blocked provider
    /// never looks like a reading.
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
        case .stale, .unavailable:
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
        static let claudeSource = "claudeSource"
        static let glassEnabled = "glassEnabled"
        static let glassOpacity = "glassOpacity"
        static let indicatorColorHex = "indicatorColorHex"
        static let verticalPosition = "verticalPosition"
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
    }

    static let staleMessage = "Showing the last known values. Refresh to update."

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GaugeZ", isDirectory: true).appendingPathComponent("last-snapshots.json")
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
                health: .stale(staleMessage)
            )
        }
    }

    static func save(_ snapshots: [UsageSnapshot]) {
        let entries = snapshots
            .filter { !$0.windows.isEmpty }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
            .map { Entry(provider: $0.provider, planName: $0.planName, windows: $0.windows, observedAt: $0.observedAt, source: $0.source) }
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
