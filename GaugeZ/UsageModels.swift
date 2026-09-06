import Foundation

/// A rail entry identifies a provider and, for Claude Code, an isolated profile.
/// The original string IDs remain unchanged so existing preferences and caches migrate.
struct ProviderID: RawRepresentable, Hashable, Codable, Identifiable, Sendable, CaseIterable {
    enum Kind: String, Sendable { case claude, cursor, codex, antigravity, glm, grok }
    let kind: Kind
    let profileSlug: String?

    private init(kind: Kind, profileSlug: String? = nil) {
        self.kind = kind
        self.profileSlug = profileSlug
    }

    static let claude = Self(kind: .claude)
    static let cursor = Self(kind: .cursor)
    static let codex = Self(kind: .codex)
    static let antigravity = Self(kind: .antigravity)
    static let glm = Self(kind: .glm)
    static let grok = Self(kind: .grok)
    static let allCases: [Self] = [.claude, .cursor, .codex, .antigravity, .glm, .grok]

    init?(rawValue: String) {
        if let kind = Kind(rawValue: rawValue) {
            self.init(kind: kind)
        } else if rawValue.hasPrefix("claude-") {
            let slug = String(rawValue.dropFirst(7))
            guard !slug.isEmpty, !slug.contains("/"), !slug.contains("\u{0}") else { return nil }
            self.init(kind: .claude, profileSlug: slug)
        } else { return nil }
    }

    var rawValue: String { profileSlug.map { "claude-\($0)" } ?? kind.rawValue }
    var id: String { rawValue }
    var supportsActivity: Bool { kind == .claude || kind == .cursor || kind == .grok }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown provider")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch kind {
        case .claude: profileSlug.map { "Claude (\($0))" } ?? "Claude"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .glm: "GLM"
        case .grok: "Grok Build"
        }
    }

    var symbolName: String {
        switch kind {
        case .claude: "asterisk"
        case .cursor: "cube.fill"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "sparkles"
        case .glm: "z.square.fill"
        case .grok: "g.circle.fill"
        }
    }

    var logoAssetName: String {
        switch kind {
        case .claude: "ClaudeLogo"
        case .cursor: "CursorLogo"
        case .codex: "OpenAILogo"
        case .antigravity: "AntigravityLogo"
        case .glm: "GLMLogo"
        case .grok: "GrokLogo"
        }
    }

    var applicationURL: URL? {
        switch kind {
        case .claude: URL(fileURLWithPath: "/Applications/Claude.app")
        case .cursor: URL(fileURLWithPath: "/Applications/Cursor.app")
        case .codex:
            URL(fileURLWithPath: FileManager.default.fileExists(atPath: "/Applications/Codex.app")
                ? "/Applications/Codex.app" : "/Applications/ChatGPT.app")
        case .antigravity:
            URL(fileURLWithPath: FileManager.default.fileExists(atPath: "/Applications/Antigravity.app")
                ? "/Applications/Antigravity.app" : "/Applications/Antigravity IDE.app")
        case .glm: URL(string: "https://z.ai/manage-apikey/apikey-list")
        case .grok: URL(string: "https://docs.x.ai/build/overview")
        }
    }

    var sourceDescription: String {
        switch kind {
        case .claude:
            profileSlug.map { "Reads the Claude Code sign-in and sessions in ~/.claude-\($0)." }
                ?? "Reads the Claude desktop usage log, or the default Claude Code CLI sign-in from Keychain."
        case .cursor: "Uses Cursor's local sign-in to ask cursor.com for plan usage."
        case .codex: "Talks to the local app-server bundled with Codex or ChatGPT."
        case .antigravity: "Asks the language server of a running Antigravity app or IDE for its model quotas."
        case .glm: "Reads Z.ai Coding Plan usage with a key held by Claude Code, ZCode, or OpenCode."
        case .grok: "Reads Grok Build’s xAI account sign-in from ~/.grok/auth.json and asks its billing service for the allowance."
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

struct ProviderCostInfo: Codable, Equatable, Sendable {
    let sessionCost: Double?
    let totalTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedTokens: Int?
    let reasoningTokens: Int?
    let modelCalls: Int?
    let apiDurationSeconds: Int?
    let projectName: String?
    let prepaidBalance: Double?

    init(
        sessionCost: Double? = nil,
        totalTokens: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        modelCalls: Int? = nil,
        apiDurationSeconds: Int? = nil,
        projectName: String? = nil,
        prepaidBalance: Double? = nil
    ) {
        self.sessionCost = sessionCost
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.modelCalls = modelCalls
        self.apiDurationSeconds = apiDurationSeconds
        self.projectName = projectName
        self.prepaidBalance = prepaidBalance
    }

    var formattedCost: String? {
        guard let sessionCost else { return nil }
        if sessionCost < 1.0 && sessionCost > 0 {
            return String(format: "$%.4f", sessionCost)
        } else {
            return String(format: "$%.2f", sessionCost)
        }
    }

    var formattedBalance: String? {
        guard let prepaidBalance else { return nil }
        return String(format: "$%.2f", prepaidBalance)
    }

    var sessionDetailLine: String? {
        var parts: [String] = []
        if let total = totalTokens, total > 0 {
            let tokensStr = total >= 1000 ? String(format: "%.1fk", Double(total) / 1000.0) : "\(total)"
            parts.append("\(tokensStr) tokens")
        }
        if let calls = modelCalls, calls > 0 {
            if let duration = apiDurationSeconds, duration > 0 {
                parts.append("\(calls) \(calls == 1 ? "call" : "calls") · \(duration)s")
            } else {
                parts.append("\(calls) \(calls == 1 ? "call" : "calls")")
            }
        }
        if let project = projectName, !project.isEmpty {
            parts.append(project)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    let costInfo: ProviderCostInfo?

    var headlineWindowID: String? = nil

    var headlineWindow: UsageWindow? {
        if let headlineWindowID {
            return windows.first { $0.id == headlineWindowID }
        }
        return windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var remainingPercent: Int? { headlineWindow?.remainingPercent }

    init(
        provider: ProviderID,
        accountID: String?,
        planName: String?,
        windows: [UsageWindow],
        observedAt: Date,
        source: String,
        health: ProviderHealth,
        costInfo: ProviderCostInfo? = nil,
        headlineWindowID: String? = nil
    ) {
        self.provider = provider
        self.accountID = accountID
        self.planName = planName
        self.windows = windows
        self.observedAt = observedAt
        self.source = source
        self.health = health
        self.costInfo = costInfo
        self.headlineWindowID = headlineWindowID
    }

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
            source: provider.sourceDescription,
            health: health,
            costInfo: nil
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
            costInfo: costInfo,
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
    func forgetCredentials()
}

extension UsageProviding {
    func forgetCredentials() {}
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
