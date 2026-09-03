import AppKit
import Combine
import Foundation
import os
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
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
                DispatchQueue.main.async { [weak self] in
                    self?.refresh(.claude)
                }
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
        "com.google.antigravity": .antigravity,
        "com.google.antigravity-ide": .antigravity
    ]

    private static let periodicInterval: Duration = .seconds(300)
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

        // Last known values from the previous run, shown as stale until a refresh succeeds.
        for cached in SnapshotCache.load() {
            snapshots[cached.provider] = cached
        }

        startPeriodicRefresh()
        observeWake()
        observeApplications()
    }

    deinit {
        periodicTask?.cancel()
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
        ProviderID.allCases.filter(enabledProviders.contains)
    }

    /// Providers that have a working adapter behind them.
    var connectedProviders: [ProviderID] {
        ProviderID.allCases.filter { providers[$0] != nil }
    }

    func snapshot(for provider: ProviderID) -> UsageSnapshot {
        snapshots[provider] ?? .placeholder(for: provider)
    }

    func setProvider(_ provider: ProviderID, enabled: Bool) {
        if enabled {
            enabledProviders.insert(provider)
            DispatchQueue.main.async { [weak self] in
                self?.refresh(provider)
            }
        } else {
            enabledProviders.remove(provider)
            refreshTasks[provider]?.cancel()
            refreshTasks[provider] = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.snapshots[provider] = .placeholder(for: provider)
                SnapshotCache.save(Array(self.snapshots.values))
            }
        }
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
        guard let adapter = providers[provider], enabledProviders.contains(provider) else { return }

        lastRefreshStarted[provider] = .now
        refreshTasks[provider]?.cancel()
        refreshTasks[provider] = Task { [weak self] in
            guard let self else { return }
            await self.refresh(provider, using: adapter)
        }
    }

    /// Refreshes after a delay, for apps whose local servers take a moment to come up.
    private func refresh(_ provider: ProviderID, after delay: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh(provider)
        }
    }

    private func refreshIfIdle(_ provider: ProviderID, for interval: TimeInterval) {
        let last = lastRefreshStarted[provider] ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return }
        refresh(provider)
    }

    func open(_ provider: ProviderID) {
        guard let url = provider.applicationURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func refresh(_ provider: ProviderID, using adapter: any UsageProviding) async {
        let previous = snapshot(for: provider)
        snapshots[provider] = previous.windows.isEmpty
            ? .placeholder(for: provider, health: .loading)
            : previous.withHealth(.loading)

        do {
            let snapshot = try await adapter.fetchSnapshot()
            guard !Task.isCancelled else { return }
            Self.note("\(provider.displayName) refreshed: \(snapshot.health.shortLabel), \(snapshot.windows.count) windows via \(snapshot.source)")
            snapshots[provider] = snapshot
            SnapshotCache.save(Array(snapshots.values))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            Self.note("\(provider.displayName) refresh failed: \(error.localizedDescription)")
            snapshots[provider] = Self.failedSnapshot(for: provider, previous: previous, error: error)
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
                try? await Task.sleep(for: Self.periodicInterval)
                guard !Task.isCancelled else { return }
                self?.refresh()
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
                self?.refresh(provider, after: .seconds(30))
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
