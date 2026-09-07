// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import Foundation

/// Reads OpenCode Go plan usage from the official endpoint, with the `opencode-go` key OpenCode
/// itself stores on sign-in. Nothing else in OpenCode's auth file is read: the other entries are
/// other vendors' keys, and claiming one would report the wrong account under OpenCode's name.
actor OpenCodeUsageProvider: UsageProviding {
    private let session: URLSession
    private let retryPolicy: ProviderRetryPolicy
    private let loadCredentials: @Sendable () -> OpenCodeCredentials.Credential?

    init(session: URLSession? = nil, retryPolicy: ProviderRetryPolicy? = nil,
         loadCredentials: @escaping @Sendable () -> OpenCodeCredentials.Credential? = { OpenCodeCredentials.load() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = session ?? URLSession(configuration: configuration)
        self.retryPolicy = retryPolicy ?? ProviderRetryPolicy(provider: .opencode)
        self.loadCredentials = loadCredentials
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        // Re-read on every fetch: an ordinary file, so no prompt, and the key rotates on sign-in.
        guard let credential = loadCredentials() else { throw OpenCodeProviderError.notSignedIn }

        var request = URLRequest(url: OpenCodeUsageParser.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GaugeZ/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OpenCodeProviderError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw OpenCodeProviderError.malformed }
        switch http.statusCode {
        case 200..<300: break
        // Upstream serves "no Go plan on this key" through the same branch as a bad key.
        case 401: throw OpenCodeProviderError.unauthorized
        // A valid key that is not entitled to Go: readable, metering nothing. Not a fault.
        case 403: throw OpenCodeProviderError.noPlan
        case 429: throw retryPolicy.throttled(response: http)
        case 500...599: throw OpenCodeProviderError.server(http.statusCode)
        default: throw OpenCodeProviderError.unexpectedStatus(http.statusCode)
        }

        let windows = try OpenCodeUsageParser.windows(from: data)
        retryPolicy.succeeded()
        return UsageSnapshot(
            provider: .opencode,
            accountID: nil,
            planName: "OpenCode Go",
            windows: windows,
            observedAt: .now,
            source: "OpenCode sign-in · opencode.ai Go plan",
            health: .live
        )
    }
}

/// The Go plan key OpenCode writes to `~/.local/share/opencode/auth.json` on `opencode auth login`.
enum OpenCodeCredentials {
    struct Credential: Sendable {
        let token: String
    }

    static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/auth.json")
    }

    static func load(from url: URL = authURL) -> Credential? {
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) < 1_048_576,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"]
        else { return nil }
        // The entry is either the key itself or an object carrying it; both shapes have shipped.
        if let token = headerSafe(entry) { return Credential(token: token) }
        guard let object = entry as? [String: Any] else { return nil }
        let token = ["key", "apiKey", "api_key", "token", "accessToken"].compactMap { headerSafe(object[$0]) }.first
        return token.map(Credential.init(token:))
    }

    /// Non-empty, single-line strings only: an empty key is a request that cannot succeed, and a
    /// key with a line break would be a header injection.
    private static func headerSafe(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.rangeOfCharacter(from: .newlines) == nil, text.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return text
    }
}

/// `GET https://opencode.ai/zen/go/v1/usage`, the same figures the OpenCode dashboard shows:
/// `{"usage":{"rolling":{"percent":0,"resetsAt":"…"},"weekly":{…},"monthly":{…}}}`.
/// `percent` is already *used*, and `resetsAt` carries milliseconds.
enum OpenCodeUsageParser {
    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    private static let descriptors: [(id: String, label: String, minutes: Int)] = [
        ("rolling", "5-hour limit", 300),
        ("weekly", "Weekly limit", 10_080),
        ("monthly", "Monthly limit", 43_200)
    ]

    static func windows(from data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any]
        else { throw OpenCodeProviderError.malformed }
        var windows: [UsageWindow] = []
        for descriptor in descriptors {
            guard let entry = usage[descriptor.id] as? [String: Any] else { continue }
            guard let percent = (entry["percent"] as? NSNumber)?.doubleValue, percent.isFinite, percent >= 0 else {
                throw OpenCodeProviderError.malformed
            }
            windows.append(UsageWindow(
                id: descriptor.id,
                label: descriptor.label,
                usedPercent: Int(min(100, percent).rounded()),
                resetsAt: (entry["resetsAt"] as? String).flatMap(date(from:)),
                durationMinutes: descriptor.minutes
            ))
        }
        guard !windows.isEmpty else { throw OpenCodeProviderError.noLimits }
        return windows
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

enum OpenCodeProviderError: LocalizedError, ProviderHealthDescribing {
    case notSignedIn
    case unauthorized
    case noPlan
    case offline(String)
    case server(Int)
    case unexpectedStatus(Int)
    case malformed
    case noLimits

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "No OpenCode Go key found. Connect Go inside OpenCode (`opencode auth login`), then retry."
        case .unauthorized: "OpenCode rejected the Go key, or this key has no Go plan. Sign in to OpenCode again."
        case .noPlan: "This OpenCode key has no Go subscription to meter."
        case .offline(let detail): "OpenCode could not be reached: \(detail)"
        case .server(let status): "OpenCode returned a server error (\(status))."
        case .unexpectedStatus(let status): "OpenCode returned an unexpected response (\(status))."
        case .malformed: "OpenCode returned an unsupported usage response."
        case .noLimits: "OpenCode reported no usage windows."
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? "OpenCode unavailable"
        switch self {
        case .notSignedIn, .unauthorized: return .signedOut(message)
        case .offline, .server: return .stale(message)
        case .noPlan, .unexpectedStatus, .malformed, .noLimits: return .unavailable(message)
        }
    }
}
