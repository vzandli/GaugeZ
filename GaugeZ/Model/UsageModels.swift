import Foundation

/// A rail entry identifies a provider and, for Claude Code, an isolated profile.
/// The original string IDs remain unchanged so existing preferences and caches migrate.
struct ProviderID: RawRepresentable, Hashable, Codable, Identifiable, Sendable, CaseIterable {
    enum Kind: String, Sendable { case claude, cursor, codex, antigravity, glm, grok, opencode, copilot }
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
    static let opencode = Self(kind: .opencode)
    static let copilot = Self(kind: .copilot)
    static let allCases: [Self] = [.claude, .cursor, .codex, .antigravity, .glm, .grok, .opencode, .copilot]

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
    var supportsActivity: Bool {
        switch kind {
        case .claude, .cursor, .grok, .codex, .antigravity: true
        case .glm, .opencode, .copilot: false
        }
    }

    /// Codex and Antigravity publish no session status; their activity is inferred from recent
    /// writes to local logs and labeled as such.
    var activityIsInferred: Bool { kind == .codex || kind == .antigravity }

    /// Providers without a bundled logo asset draw an SF Symbol instead.
    var usesSymbolLogo: Bool { kind == .glm || kind == .opencode }

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
        case .opencode: "OpenCode"
        case .copilot: "GitHub Copilot"
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
        case .opencode: "terminal.fill"
        case .copilot: "c.circle.fill"
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
        case .opencode: "OpenCodeLogo"
        case .copilot: "CopilotLogo"
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
        case .opencode: URL(string: "https://opencode.ai")
        case .copilot: URL(string: "https://github.com/settings/copilot")
        }
    }

    var sourceDescription: String {
        switch kind {
        case .claude:
            profileSlug.map { String(localized: "Reads the Claude Code sign-in and sessions in ~/.claude-\($0).", bundle: .language) }
                ?? String(localized: "Reads the Claude desktop usage log, or the default Claude Code CLI sign-in from Keychain.", bundle: .language)
        case .cursor: String(localized: "Uses Cursor's local sign-in to ask cursor.com for plan usage.", bundle: .language)
        case .codex: String(localized: "Talks to the local app-server bundled with Codex, ChatGPT, or the codex CLI; without one, reads ChatGPT's usage endpoint with the CLI sign-in.", bundle: .language)
        case .antigravity: String(localized: "Reads the local Antigravity server, then Google quota with the saved sign-in, or derives model turns from local transcripts.", bundle: .language)
        case .glm: String(localized: "Reads Z.ai Coding Plan usage with a key held by Claude Code, ZCode, or OpenCode.", bundle: .language)
        case .grok: String(localized: "Reads Grok Build’s xAI account sign-in from ~/.grok/auth.json and asks its billing service for the allowance.", bundle: .language)
        case .opencode: String(localized: "Reads OpenCode Go plan usage with the opencode-go key OpenCode stores on sign-in.", bundle: .language)
        case .copilot: String(localized: "Reads Copilot quotas using GH_TOKEN or the GitHub CLI sign-in. Run gh auth login to connect.", bundle: .language)
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
        case .loading: String(localized: "Refreshing", bundle: .language)
        case .live: String(localized: "Live", bundle: .language)
        case .stale: String(localized: "Stale", bundle: .language)
        case .signedOut: String(localized: "Signed out", bundle: .language)
        case .permissionRequired: String(localized: "Permission needed", bundle: .language)
        case .unavailable: String(localized: "Unavailable", bundle: .language)
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

/// "How long has it been like this": the second half of answering whether a session is still working.
enum ElapsedCopy {
    static func text(since: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 45 { return String(localized: "just now", bundle: .language) }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return String.localizedStringWithFormat(String(localized: "%lld min", bundle: .language), Int64(max(1, minutes)))
        }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 {
            return String.localizedStringWithFormat(String(localized: "%lld hr", bundle: .language), Int64(hours))
        }
        return String.localizedStringWithFormat(String(localized: "%lld hr %lld min", bundle: .language), Int64(hours), Int64(rest))
    }
}

/// How many session rows a detail card carries, solved for the display it is on: enough to be
/// useful on a large screen, never so many the card's own buttons scroll off a small one. The
/// rest is counted, not drawn.
enum SessionListCap {
    static let minimum = 3
    static let maximum = 12
    /// Roughly what the card spends on everything but session rows, and what one row costs.
    static let fixedOverhead: CGFloat = 420
    static let rowHeight: CGFloat = 34

    static func count(visibleHeight: CGFloat) -> Int {
        let rows = Int((visibleHeight - fixedOverhead) / rowHeight)
        return max(minimum, min(maximum, rows))
    }
}

/// Reset times as the cards print them. A weekday only identifies a day inside the coming week:
/// a monthly window resetting in four weeks read as "Mon", this coming Monday, so beyond seven
/// calendar days the date is shown instead.
enum ResetCopy {
    static func absolute(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if abs(date.timeIntervalSince(now)) < 20 * 60 * 60 {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if daysApart(from: now, to: date, calendar: calendar) >= 7 {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Whole calendar days, so a clock change cannot shift the answer.
    static func daysApart(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }
}

struct UsageWindow: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    let durationMinutes: Int?

    var remainingPercent: Double {
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
            parts.append(String(localized: "\(tokensStr) tokens", bundle: .language))
        }
        if let calls = modelCalls, calls > 0 {
            if let duration = apiDurationSeconds, duration > 0 {
                parts.append(String(localized: "\(Int(calls)) calls · \(Int(duration))s", bundle: .language))
            } else {
                parts.append(String(localized: "\(Int(calls)) calls", bundle: .language))
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
    let derivedRequestCount: Int?

    var headlineWindowID: String? = nil

    var headlineWindow: UsageWindow? {
        if let headlineWindowID {
            return windows.first { $0.id == headlineWindowID }
        }
        return windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var remainingPercent: Double? { headlineWindow?.remainingPercent }

    init(
        provider: ProviderID,
        accountID: String?,
        planName: String?,
        windows: [UsageWindow],
        observedAt: Date,
        source: String,
        health: ProviderHealth,
        costInfo: ProviderCostInfo? = nil,
        headlineWindowID: String? = nil,
        derivedRequestCount: Int? = nil
    ) {
        self.provider = provider
        self.accountID = accountID
        self.planName = planName
        self.windows = windows
        self.observedAt = observedAt
        self.source = source
        self.health = health
        self.derivedRequestCount = derivedRequestCount
        self.costInfo = costInfo
        self.headlineWindowID = headlineWindowID
    }

    static func placeholder(
        for provider: ProviderID,
        health: ProviderHealth = .unavailable(String(localized: "Adapter not connected yet", bundle: .language))
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
            headlineWindowID: headlineWindowID,
            derivedRequestCount: derivedRequestCount
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
        case .desktop: String(localized: "Desktop app", bundle: .language)
        case .claudeCode: String(localized: "Claude Code CLI", bundle: .language)
        }
    }

    var summary: String {
        switch self {
        case .desktop: String(localized: "Reads Claude Desktop's sign-in via Keychain for live reset times, or falls back to the desktop usage log.", bundle: .language)
        case .claudeCode: String(localized: "Reads the Claude Code CLI sign-in from Keychain and asks Claude directly. macOS will ask you to allow it.", bundle: .language)
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
        case .always: String(localized: "Always show", bundle: .language)
        case .hover: String(localized: "Show on hover", bundle: .language)
        case .hidden: String(localized: "Hide", bundle: .language)
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
    var label: String {
        switch self {
        case .right: String(localized: "Right", bundle: .language)
        case .left: String(localized: "Left", bundle: .language)
        case .top: String(localized: "Top", bundle: .language)
        case .bottom: String(localized: "Bottom", bundle: .language)
        }
    }
}

/// Keep exact values for rings and thresholds; round only at the last display step.
enum PercentCopy {
    static func text(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let value = max(0, min(100, value))
        if value > 0 && value < 0.1 { return "<0.1" }
        if value > 0 && value < 1 { return String(format: "%.1f", min(0.9, value)) }
        if value > 99 && value < 100 { return value > 99.9 ? ">99.9" : String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }
}
