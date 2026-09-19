// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import Foundation

/// Reads Command Code usage from the same `/alpha` endpoints its desktop app uses, with the key
/// the app writes to `~/.commandcode/auth.json`. Four documents answer one question: `whoami`
/// names the org every other call is scoped to, `subscriptions` dates the billing period,
/// `credits` holds the remaining allowance, and `usage/summary` holds what has been spent since
/// the period began.
actor CommandCodeUsageProvider: UsageProviding {
    private let session: URLSession
    private let retryPolicy: ProviderRetryPolicy
    private let loadCredentials: @Sendable () throws -> CommandCodeCredential

    init(session: URLSession? = nil, retryPolicy: ProviderRetryPolicy? = nil,
         loadCredentials: @escaping @Sendable () throws -> CommandCodeCredential = { try CommandCodeCredentialReader.load() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = session ?? URLSession(configuration: configuration)
        self.retryPolicy = retryPolicy ?? ProviderRetryPolicy(provider: .commandcode)
        self.loadCredentials = loadCredentials
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        // Re-read on every fetch: an ordinary file, so no prompt, and the app rotates the key.
        let credential = try loadCredentials()

        let whoami = try await body(from: CommandCodeUsageParser.whoami, token: credential.apiKey)
        let orgID = CommandCodeUsageParser.orgID(whoami: whoami)

        async let creditsTask = body(from: CommandCodeUsageParser.credits.withQuery(["orgId": orgID]), token: credential.apiKey)
        async let subscriptionTask = body(from: CommandCodeUsageParser.subscriptions.withQuery(["orgId": orgID]), token: credential.apiKey)
        let credits = try await creditsTask
        let subscription = try await subscriptionTask

        // Spend is only comparable to the allowance when counted from the same period start.
        var summaryQuery: [String: String?] = ["orgId": orgID]
        if let start = CommandCodeUsageParser.date(CommandCodeUsageParser.subscriptionData(subscription)["currentPeriodStart"]) {
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            summaryQuery["since"] = stamp.string(from: start)
        }
        let summary = try await body(from: CommandCodeUsageParser.summary.withQuery(summaryQuery), token: credential.apiKey)

        let read = try CommandCodeUsageParser.read(summary: summary, credits: credits, subscription: subscription)
        retryPolicy.succeeded()
        return UsageSnapshot(
            provider: .commandcode,
            accountID: credential.userName,
            planName: read.plan.map { "Command Code \($0)" } ?? "Command Code",
            windows: read.windows,
            observedAt: .now,
            source: "Command Code sign-in · api.commandcode.ai",
            health: .live,
            // Credits that never became a percent are still worth showing as money.
            costInfo: read.balance.map { ProviderCostInfo(prepaidBalance: $0) },
            headlineWindowID: read.windows.contains { $0.id == "monthly" } ? "monthly" : nil
        )
    }

    private func body(from url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GaugeZ/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CommandCodeProviderError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CommandCodeProviderError.malformed }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw CommandCodeProviderError.unauthorized
        case 429: throw retryPolicy.throttled(response: http)
        case 500...599: throw CommandCodeProviderError.server(http.statusCode)
        default: throw CommandCodeProviderError.unexpectedStatus(http.statusCode)
        }
    }
}

/// The key the Command Code desktop app writes on login. `COMMAND_CODE_API_KEY` wins when set,
/// matching the app's own harness.
struct CommandCodeCredential: Sendable {
    let apiKey: String
    let userName: String?
}

enum CommandCodeCredentialReader {
    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".commandcode/auth.json")
    }

    static func load(from url: URL = authURL,
                     environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CommandCodeCredential {
        if let key = headerSafe(environment["COMMAND_CODE_API_KEY"]) {
            return CommandCodeCredential(apiKey: key, userName: nil)
        }
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) < 1_048_576,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = headerSafe(root["apiKey"] as? String)
        else { throw CommandCodeProviderError.notSignedIn }
        let name = (root["userName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandCodeCredential(apiKey: key, userName: (name?.isEmpty ?? true) ? nil : name)
    }

    /// Non-empty, single-line strings only: an empty key is a request that cannot succeed, and a
    /// key with a line break would be a header injection.
    private static func headerSafe(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.rangeOfCharacter(from: .newlines) == nil, text.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return text
    }
}

/// Turns Command Code's billing documents into percent-used windows.
///
/// - `GET /alpha/usage/summary` → `{"totalCost": 3.5, …}`
/// - `GET /alpha/billing/credits` → `{"credits":{"monthlyCredits": 16.5},"windowLimits":{"fiveHour":{"used":…,"cap":…,"resetAt":…},"weekly":{…}}}`
/// - `GET /alpha/billing/subscriptions` → `{"data":{"planId":"goat_monthly","currentPeriodEnd":…}}`
///
/// The monthly ring is spend over the pot it came out of (`totalCost + monthlyCredits`); the
/// five-hour and weekly rows already state their own caps. A `resetAt` of 0 is absence, not 1970.
enum CommandCodeUsageParser {
    static let whoami = URL(string: "https://api.commandcode.ai/alpha/whoami")!
    static let credits = URL(string: "https://api.commandcode.ai/alpha/billing/credits")!
    static let subscriptions = URL(string: "https://api.commandcode.ai/alpha/billing/subscriptions")!
    static let summary = URL(string: "https://api.commandcode.ai/alpha/usage/summary")!

    struct Read: Sendable {
        let windows: [UsageWindow]
        let plan: String?
        /// Remaining credits in dollars, shown when they are money rather than a percentage.
        let balance: Double?
    }

    static func read(summary summaryBody: Data, credits creditsBody: Data, subscription subscriptionBody: Data) throws -> Read {
        guard let summary = object(summaryBody), let creditsRoot = object(creditsBody) else {
            throw CommandCodeProviderError.malformed
        }
        let credits = (creditsRoot["credits"] as? [String: Any]) ?? [:]
        let limits = (creditsRoot["windowLimits"] as? [String: Any]) ?? [:]
        let subscription = subscriptionData(subscriptionBody)

        let used = number(summary["totalCost"]) ?? 0
        let remaining = number(credits["monthlyCredits"])
        let cap = used + (remaining ?? 0)

        var windows: [UsageWindow] = []
        // A pot of zero is not a 0%-used month: there is simply no allowance to measure against.
        if cap > 0 {
            windows.append(UsageWindow(
                id: "monthly",
                label: String(localized: "Monthly limit", bundle: .language),
                usedPercent: min(100, used / cap * 100),
                resetsAt: date(subscription["currentPeriodEnd"]),
                durationMinutes: 43_200
            ))
        }
        if let five = window(limits["fiveHour"], id: "fiveHour",
                             label: String(localized: "5-hour limit", bundle: .language), minutes: 300) {
            windows.append(five)
        }
        if let weekly = window(limits["weekly"], id: "weekly",
                               label: String(localized: "Weekly limit", bundle: .language), minutes: 10_080) {
            windows.append(weekly)
        }
        guard !windows.isEmpty else { throw CommandCodeProviderError.nothingMetered }

        return Read(windows: windows, plan: planName(subscription["planId"] as? String),
                    balance: remaining.map { max(0, $0) })
    }

    /// The subscription body, which has shipped both wrapped in `data` and bare.
    static func subscriptionData(_ data: Data) -> [String: Any] {
        guard let root = object(data) else { return [:] }
        return (root["data"] as? [String: Any]) ?? root
    }

    static func orgID(whoami: Data) -> String? {
        guard let root = object(whoami), let org = root["org"] as? [String: Any] else { return nil }
        let id = (org["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty ?? true) ? nil : id
    }

    static func planName(_ planID: String?) -> String? {
        guard let planID, !planID.isEmpty else { return nil }
        return planID.lowercased().replacingOccurrences(of: "-", with: "_").contains("goat") ? "GOAT" : planID
    }

    /// A capped window. Without a cap there is no percentage to state, so the row is dropped
    /// rather than guessed at; a cap with an unreadable `used` is malformed, never zero.
    private static func window(_ any: Any?, id: String, label: String, minutes: Int) -> UsageWindow? {
        guard let entry = any as? [String: Any], let cap = number(entry["cap"]), cap > 0,
              let used = number(entry["used"]), used >= 0
        else { return nil }
        return UsageWindow(
            id: id,
            label: label,
            usedPercent: min(100, used / cap * 100),
            resetsAt: date(entry["resetAt"]),
            durationMinutes: minutes
        )
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func number(_ any: Any?) -> Double? {
        guard let value = (any as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }

    /// ISO 8601, unix seconds, or unix milliseconds. Zero is "no reset".
    static func date(_ any: Any?) -> Date? {
        if let text = any as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: text)
        }
        guard var unix = number(any), unix > 0 else { return nil }
        if unix > 1_000_000_000_000 { unix /= 1000 }
        return Date(timeIntervalSince1970: unix)
    }
}

private extension URL {
    func withQuery(_ items: [String: String?]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        let pairs = items.compactMap { key, value -> URLQueryItem? in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        if !pairs.isEmpty { components.queryItems = pairs.sorted { $0.name < $1.name } }
        return components.url ?? self
    }
}

enum CommandCodeProviderError: LocalizedError, ProviderHealthDescribing {
    case notSignedIn
    case unauthorized
    case offline(String)
    case server(Int)
    case unexpectedStatus(Int)
    case malformed
    case nothingMetered

    var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "No Command Code sign-in found. Sign in with the Command Code app, then retry.", bundle: .language)
        case .unauthorized: String(localized: "Command Code rejected the saved key. Sign in with the Command Code app again.", bundle: .language)
        case .offline(let detail): String(localized: "Command Code could not be reached: \(detail)", bundle: .language)
        case .server(let status): String(localized: "Command Code returned a server error (\(status)).", bundle: .language)
        case .unexpectedStatus(let status): String(localized: "Command Code returned an unexpected response (\(status)).", bundle: .language)
        case .malformed: String(localized: "Command Code returned an unsupported billing response.", bundle: .language)
        case .nothingMetered: String(localized: "Command Code has nothing metered on this account yet.", bundle: .language)
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? String(localized: "Command Code unavailable", bundle: .language)
        switch self {
        case .notSignedIn, .unauthorized: return .signedOut(message)
        case .offline, .server: return .stale(message)
        case .unexpectedStatus, .malformed, .nothingMetered: return .unavailable(message)
        }
    }
}
