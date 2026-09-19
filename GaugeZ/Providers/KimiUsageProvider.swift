// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import Foundation

/// Reads Kimi Code usage from the endpoint the `kimi` CLI's own `/usage` asks, with the OAuth
/// session the CLI writes on sign-in. The token lives fifteen minutes and the CLI renews it as it
/// runs; GaugeZ never mints a new one, because writing the file would race the CLI for it — an
/// expired token is reported as a sign-in to redo, not as a failure.
actor KimiUsageProvider: UsageProviding {
    private let session: URLSession
    private let retryPolicy: ProviderRetryPolicy
    private let loadCredential: @Sendable () throws -> KimiCredential

    init(session: URLSession? = nil, retryPolicy: ProviderRetryPolicy? = nil,
         loadCredential: @escaping @Sendable () throws -> KimiCredential = { try KimiCredentialReader.load() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = session ?? URLSession(configuration: configuration)
        self.retryPolicy = retryPolicy ?? ProviderRetryPolicy(provider: .kimi)
        self.loadCredential = loadCredential
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        // Re-read on every fetch: an ordinary file, so no prompt, and the CLI rotates the token
        // every fifteen minutes.
        let credential = try loadCredential()
        guard credential.expiresAt > .now else { throw KimiProviderError.expired }

        var request = URLRequest(url: KimiUsageParser.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GaugeZ/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw KimiProviderError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw KimiProviderError.malformed }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw KimiProviderError.unauthorized
        // The endpoint's own answer for an account without a Kimi Code plan: readable, metering
        // nothing. Not a fault.
        case 404: throw KimiProviderError.noPlan
        case 429: throw retryPolicy.throttled(response: http)
        case 500...599: throw KimiProviderError.server(http.statusCode)
        default: throw KimiProviderError.unexpectedStatus(http.statusCode)
        }

        let read = try KimiUsageParser.read(from: data)
        retryPolicy.succeeded()
        return UsageSnapshot(
            provider: .kimi,
            accountID: nil,
            planName: read.plan.map { "Kimi Code \($0)" } ?? "Kimi Code",
            windows: read.windows,
            observedAt: .now,
            source: "Kimi Code sign-in · api.kimi.com",
            health: .live,
            headlineWindowID: read.windows.contains { $0.id == "rolling" } ? "rolling" : nil
        )
    }
}

/// The OAuth session the Kimi Code CLI writes to `~/.kimi-code/credentials/kimi-code.json` on
/// `/login`. One file per managed provider; `kimi-code` is the Kimi Code account itself.
struct KimiCredential: Sendable {
    let accessToken: String
    let expiresAt: Date
}

enum KimiCredentialReader {
    /// `KIMI_CODE_HOME` moves the whole data root, so the path honours it.
    static func authURL(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let root: URL
        if let custom = environment["KIMI_CODE_HOME"], !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            root = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : home.appendingPathComponent(".kimi-code")
        } else {
            root = home.appendingPathComponent(".kimi-code")
        }
        return root.appendingPathComponent("credentials/kimi-code.json")
    }

    static func load(from url: URL = authURL()) throws -> KimiCredential {
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) < 1_048_576,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = headerSafe(root["access_token"])
        else { throw KimiProviderError.notSignedIn }
        // `expires_at` is epoch seconds. A file without one is not a session to trust with a
        // request that cannot succeed.
        guard let expires = (root["expires_at"] as? NSNumber)?.doubleValue, expires > 0 else {
            throw KimiProviderError.notSignedIn
        }
        return KimiCredential(accessToken: token, expiresAt: Date(timeIntervalSince1970: expires))
    }

    /// Non-empty, single-line strings only: an empty token is a request that cannot succeed, and
    /// a token with a line break would be a header injection.
    private static func headerSafe(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.rangeOfCharacter(from: .newlines) == nil, text.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return text
    }
}

/// Parses `GET https://api.kimi.com/coding/v1/usages`:
/// `{"user":{"membership":{"level":"LEVEL_ADVANCED"}},
///   "usage":{"limit":"100","used":"2","resetTime":"…"},
///   "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{…}}]}`
///
/// Two shapes of the same row: `usage` is the account summary — the weekly window, which is what
/// the CLI assumes when no window is stated — and each `limits[]` entry names its own window.
/// Counts arrive as decimal *strings*. The Extra Usage wallet (`boosterWallet`) is money, not a
/// window, and is left out.
enum KimiUsageParser {
    static let endpoint = URL(string: "https://api.kimi.com/coding/v1/usages")!

    struct Read: Sendable {
        let windows: [UsageWindow]
        /// The membership tier as the account names it (`LEVEL_ADVANCED` → "Advanced").
        let plan: String?
    }

    static func read(from data: Data) throws -> Read {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KimiProviderError.malformed
        }

        var windows: [UsageWindow] = []
        if let summary = root["usage"] as? [String: Any],
           let window = try row(id: "weekly", label: String(localized: "Weekly limit", bundle: .language),
                                from: summary, minutes: 10_080) {
            windows.append(window)
        }
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            guard let detail = entry["detail"] as? [String: Any],
                  let kind = windowKind(from: entry["window"]),
                  !windows.contains(where: { $0.id == kind.id })
            else { continue }
            if let window = try row(id: kind.id, label: kind.label, from: detail, minutes: kind.minutes) {
                windows.append(window)
            }
        }
        guard !windows.isEmpty else { throw KimiProviderError.noLimits }
        return Read(windows: windows, plan: plan(from: root))
    }

    /// One metered row. A row without a usable denominator is a bare count, which a percent ring
    /// cannot say anything about, so it is dropped — but an unreadable `used` is malformed data,
    /// never zero usage.
    private static func row(id: String, label: String, from detail: [String: Any], minutes: Int) throws -> UsageWindow? {
        guard let used = count(detail["used"]), used >= 0 else { throw KimiProviderError.malformed }
        guard let limit = count(detail["limit"]), limit > 0 else { return nil }
        return UsageWindow(
            id: id,
            label: label,
            usedPercent: min(100, Double(used) / Double(limit) * 100),
            resetsAt: (detail["resetTime"] as? String).flatMap(date(from:)),
            durationMinutes: minutes
        )
    }

    /// Only the windows Kimi meters today — the 5-hour rate window and the weekly quota — get
    /// named; anything else is left out rather than mislabelled.
    private static func windowKind(from raw: Any?) -> (id: String, label: String, minutes: Int)? {
        guard let window = raw as? [String: Any],
              let duration = count(window["duration"]), duration > 0,
              let unit = window["timeUnit"] as? String
        else { return nil }
        switch unit {
        case "TIME_UNIT_MINUTE" where duration == 300, "TIME_UNIT_HOUR" where duration == 5:
            return ("rolling", String(localized: "5-hour limit", bundle: .language), 300)
        case "TIME_UNIT_WEEK" where duration == 1:
            return ("weekly", String(localized: "Weekly limit", bundle: .language), 10_080)
        default:
            return nil
        }
    }

    /// `LEVEL_ADVANCED` → "Advanced"; the raw level when there is no prefix to strip.
    private static func plan(from root: [String: Any]) -> String? {
        guard let user = root["user"] as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let level = membership["level"] as? String, !level.isEmpty
        else { return nil }
        let name = level.hasPrefix("LEVEL_") ? String(level.dropFirst(6)) : level
        return name.isEmpty ? nil : name.lowercased().capitalized
    }

    /// Counts are decimal strings in the wire format, but numbers have shipped too.
    private static func count(_ any: Any?) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        guard let text = any as? String else { return nil }
        return Int(text.trimmingCharacters(in: .whitespaces))
    }

    static func date(from stamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: stamp) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: stamp)
    }
}

enum KimiProviderError: LocalizedError, ProviderHealthDescribing {
    case notSignedIn
    case expired
    case unauthorized
    case noPlan
    case offline(String)
    case server(Int)
    case unexpectedStatus(Int)
    case malformed
    case noLimits

    var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "No Kimi Code sign-in found. Run kimi and sign in with /login.", bundle: .language)
        case .expired: String(localized: "The Kimi Code session expired. Run kimi to refresh it.", bundle: .language)
        case .unauthorized: String(localized: "Kimi rejected the saved session. Run kimi and sign in again.", bundle: .language)
        case .noPlan: String(localized: "This account has no Kimi Code plan to meter.", bundle: .language)
        case .offline(let detail): String(localized: "Kimi could not be reached: \(detail)", bundle: .language)
        case .server(let status): String(localized: "Kimi returned a server error (\(status)).", bundle: .language)
        case .unexpectedStatus(let status): String(localized: "Kimi returned an unexpected response (\(status)).", bundle: .language)
        case .malformed: String(localized: "Kimi returned an unsupported usage response.", bundle: .language)
        case .noLimits: String(localized: "Kimi reported no usage limits on this account.", bundle: .language)
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? String(localized: "Kimi unavailable", bundle: .language)
        switch self {
        case .notSignedIn, .expired, .unauthorized: return .signedOut(message)
        case .offline, .server: return .stale(message)
        case .noPlan, .unexpectedStatus, .malformed, .noLimits: return .unavailable(message)
        }
    }
}
