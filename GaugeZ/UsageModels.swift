import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case cursor
    case codex
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "asterisk"
        case .cursor: "cube.fill"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "sparkles"
        }
    }

    /// Template image asset holding the brand mark.
    var logoAssetName: String {
        switch self {
        case .claude: "ClaudeLogo"
        case .cursor: "CursorLogo"
        case .codex: "OpenAILogo"
        case .antigravity: "AntigravityLogo"
        }
    }

    var applicationURL: URL? {
        switch self {
        case .claude: URL(fileURLWithPath: "/Applications/Claude.app")
        case .cursor: URL(fileURLWithPath: "/Applications/Cursor.app")
        case .codex:
            FileManager.default.fileExists(atPath: "/Applications/Codex.app")
                ? URL(fileURLWithPath: "/Applications/Codex.app")
                : URL(fileURLWithPath: "/Applications/ChatGPT.app")
        case .antigravity:
            FileManager.default.fileExists(atPath: "/Applications/Antigravity.app")
                ? URL(fileURLWithPath: "/Applications/Antigravity.app")
                : URL(fileURLWithPath: "/Applications/Antigravity IDE.app")
        }
    }

    /// Short explanation of where the adapter reads from, shown in Settings.
    var sourceDescription: String {
        switch self {
        case .claude: "Reads the usage log the Claude desktop app keeps, or the Claude Code CLI sign-in from Keychain."
        case .cursor: "Uses Cursor's local sign-in to ask cursor.com for plan usage."
        case .codex: "Talks to the local app-server bundled with Codex or ChatGPT."
        case .antigravity: "Asks the language server of a running Antigravity app or IDE for its model quotas."
        }
    }
}

enum ProviderHealth: Equatable, Sendable {
    case loading
    case live
    case stale(String)
    case signedOut(String)
    case permissionRequired(String)
    case unavailable(String)

    var shortLabel: String {
        switch self {
        case .loading: "Refreshing"
        case .live: "Live"
        case .stale: "Stale"
        case .signedOut: "Signed out"
        case .permissionRequired: "Permission needed"
        case .unavailable: "Unavailable"
        }
    }

    /// Human-readable detail for the current state, if the state carries one.
    var message: String? {
        switch self {
        case .loading, .live: nil
        case .stale(let text), .signedOut(let text), .permissionRequired(let text), .unavailable(let text): text
        }
    }

    var isPermissionRequired: Bool {
        if case .permissionRequired = self { return true }
        return false
    }
}

struct UsageWindow: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let label: String
    let usedPercent: Int
    let resetsAt: Date?
    let durationMinutes: Int?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }
}

struct UsageSnapshot: Identifiable, Equatable, Sendable {
    var id: ProviderID { provider }

    let provider: ProviderID
    let accountID: String?
    let planName: String?
    let windows: [UsageWindow]
    let observedAt: Date
    let source: String
    let health: ProviderHealth

    var headlineWindowID: String? = nil

    var headlineWindow: UsageWindow? {
        if let headlineWindowID {
            return windows.first { $0.id == headlineWindowID }
        }
        return windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var remainingPercent: Int? { headlineWindow?.remainingPercent }

    static func placeholder(
        for provider: ProviderID,
        health: ProviderHealth = .unavailable("Adapter not connected yet")
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            accountID: nil,
            planName: nil,
            windows: [],
            observedAt: .now,
            source: "Not connected",
            health: health
        )
    }

    /// Keeps the last valid values but marks them with a new health state.
    func withHealth(_ health: ProviderHealth) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            accountID: accountID,
            planName: planName,
            windows: windows,
            observedAt: observedAt,
            source: source,
            health: health,
            headlineWindowID: headlineWindowID
        )
    }
}

extension Notification.Name {
    static let gaugezOpenSettings = Notification.Name("GaugeZ.openSettings")
}

/// One adapter per provider. A single call returns a fresh, validated snapshot or throws.
protocol UsageProviding: Sendable {
    func fetchSnapshot() async throws -> UsageSnapshot
}

/// Errors that know which health state they should put the provider into.
protocol ProviderHealthDescribing: Error {
    var providerHealth: ProviderHealth { get }
}

/// Where Claude usage is read from. Both describe the same account limits.
enum ClaudeSource: String, CaseIterable, Identifiable, Sendable {
    case desktop
    case claudeCode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .desktop: "Desktop app"
        case .claudeCode: "Claude Code CLI"
        }
    }

    var summary: String {
        switch self {
        case .desktop: "Reads Claude Desktop's sign-in via Keychain for live reset times, or falls back to the desktop usage log."
        case .claudeCode: "Reads the Claude Code CLI sign-in from Keychain and asks Claude directly. macOS will ask you to allow it."
        }
    }
}

enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    case always
    case hover
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: "Always show"
        case .hover: "Show on hover"
        case .hidden: "Hide"
        }
    }
}

enum EdgeSide: String, CaseIterable, Identifiable, Sendable {
    case right
    case left
    case top
    case bottom

    var isHorizontal: Bool { self == .top || self == .bottom }
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
