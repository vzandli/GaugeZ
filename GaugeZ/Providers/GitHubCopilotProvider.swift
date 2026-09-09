import Foundation

/// Adapted from Codenotch; see ThirdPartyNotices.txt.
actor GitHubCopilotProvider: UsageProviding {
    private let session: URLSession
    private let loadCredentials: @Sendable () throws -> GitHubCopilotCredentials
    private let retryPolicy: ProviderRetryPolicy

    init(session: URLSession = URLSession(configuration: .ephemeral),
         retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy(provider: .copilot),
         loadCredentials: @escaping @Sendable () throws -> GitHubCopilotCredentials = { try GitHubCopilotCredentials.load() }) {
        self.retryPolicy = retryPolicy
        self.session = session
        self.loadCredentials = loadCredentials
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        let credentials = try loadCredentials()
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GaugeZ", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CopilotProviderError.malformed }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw CopilotProviderError.signedOut
        case 429: throw retryPolicy.throttled(response: http)
        default: throw CopilotProviderError.status(http.statusCode)
        }
        let windows = try GitHubCopilotUsage.windows(from: data)
        retryPolicy.succeeded()
        return UsageSnapshot(provider: .copilot, accountID: credentials.username, planName: "GitHub Copilot",
                             windows: windows, observedAt: .now, source: credentials.source, health: .live,
                             headlineWindowID: windows.contains { $0.id == "premium_interactions" } ? "premium_interactions" : windows.first?.id)
    }
}

enum CopilotProviderError: LocalizedError, ProviderHealthDescribing {
    case signedOut, malformed, nothingMetered, status(Int)
    var errorDescription: String? {
        switch self {
        case .signedOut: String(localized: "Sign in with gh auth login, or set GH_TOKEN, using an account with GitHub Copilot access.", bundle: .language)
        case .malformed: String(localized: "GitHub Copilot returned an unsupported quota response.", bundle: .language)
        case .nothingMetered: String(localized: "GitHub Copilot reports no metered quotas.", bundle: .language)
        case .status(let code): String(localized: "GitHub Copilot returned HTTP \(code).", bundle: .language)
        }
    }
    var providerHealth: ProviderHealth {
        if case .signedOut = self { return .signedOut(errorDescription!) }
        if case .status = self { return .stale(errorDescription!) }
        return .unavailable(errorDescription!)
    }
}

struct GitHubCopilotCredentials: Sendable {
    let token: String
    let username: String?
    let source: String

    static var hostsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/gh/hosts.yml")
    }

    static func load() throws -> GitHubCopilotCredentials {
        let environment = ProcessInfo.processInfo.environment
        let hosts = try? String(contentsOf: hostsURL, encoding: .utf8)
        return try load(environment: environment, hosts: hosts, command: ghToken)
    }

    /// Injectable inputs keep credential discovery testable without touching a
    /// real token or starting GitHub CLI.
    static func load(environment: [String: String],
                     hosts: String?,
                     command: () -> String?) throws -> GitHubCopilotCredentials {
        let parsed = parseHosts(hosts)
        if let token = nonEmpty(environment["GH_TOKEN"]) ?? nonEmpty(environment["GITHUB_TOKEN"]) {
            return GitHubCopilotCredentials(token: token, username: parsed.username,
                                            source: "GitHub")
        }
        if let token = parsed.token {
            return GitHubCopilotCredentials(token: token, username: parsed.username,
                                            source: "GitHub CLI")
        }
        if let token = nonEmpty(command()) {
            return GitHubCopilotCredentials(token: token, username: parsed.username,
                                            source: "GitHub CLI")
        }
        throw CopilotProviderError.signedOut
    }

    private static func ghToken() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "token", "--hostname", "github.com"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8).flatMap(nonEmpty)
    }

    private static func parseHosts(_ text: String?) -> (username: String?, token: String?) {
        guard let text else { return (nil, nil) }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0 == "github.com:"
        }) else { return (nil, nil) }

        var username: String?
        var token: String?
        var propertyIndent: Int?
        var inUsers = false
        var userIndent: Int?
        var nestedUser: String?
        var userTokens: [String: String] = [:]
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            let indent = line.count - trimmed.count
            if propertyIndent == nil { propertyIndent = indent }
            if indent == propertyIndent {
                inUsers = trimmed == "users:"
                nestedUser = nil
                if let value = yamlValue(trimmed, key: "user") { username = value }
                if let value = yamlValue(trimmed, key: "oauth_token") { token = value }
            } else if inUsers {
                if userIndent == nil { userIndent = indent }
                if indent == userIndent, trimmed.hasSuffix(":") {
                    nestedUser = String(trimmed.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } else if let nestedUser, let value = yamlValue(trimmed, key: "oauth_token") {
                    userTokens[nestedUser] = value
                }
            }
        }
        return (username, token ?? username.flatMap { userTokens[$0] })
    }

    private static func yamlValue(_ line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        let value = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        return nonEmpty(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum GitHubCopilotUsage {
    private static let order = ["premium_interactions", "chat", "completions"]

    static func windows(from data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quotas = root["quota_snapshots"] as? [String: Any]
        else { throw CopilotProviderError.malformed }

        let keys = order + quotas.keys.filter { !order.contains($0) }.sorted()
        let windows = keys.compactMap { key -> UsageWindow? in
            guard let quota = quotas[key] as? [String: Any] else { return nil }
            return window(id: key, quota: quota, root: root)
        }
        guard !windows.isEmpty else {
            throw CopilotProviderError.nothingMetered
        }
        return windows
    }

    private static func window(id: String, quota: [String: Any], root: [String: Any]) -> UsageWindow? {
        if (quota["unlimited"] as? Bool) == true { return nil }

        let entitlement = number(quota["entitlement"])
        let remaining = number(quota["remaining"])
        let used = number(quota["used"])
        let reset = date(quota["reset_date"] ?? quota["reset_at"] ?? quota["resets_at"])
            ?? date(root["quota_reset_date_utc"]) ?? date(root["quota_reset_date"])

        guard let entitlement, entitlement.isFinite, entitlement > 0 else { return nil }
        guard let consumed = used ?? remaining.map({ entitlement - $0 }),
              consumed.isFinite, consumed >= 0 else { return nil }
        return UsageWindow(id: id, label: label(for: id), usedPercent: min(100, consumed / entitlement * 100),
                           resetsAt: reset, durationMinutes: nil)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return fractional.date(from: text) ?? plain.date(from: text) ?? day.date(from: text)
    }

    private static func label(for id: String) -> String {
        switch id {
        case "premium_interactions": return String(localized: "Premium requests", bundle: .language)
        case "chat":                return String(localized: "Chat requests", bundle: .language)
        case "completions":         return String(localized: "Completions", bundle: .language)
        default:
            return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
