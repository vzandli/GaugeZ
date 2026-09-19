// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import Foundation

/// Reads Ollama cloud usage from `https://ollama.com/api/usage` with a key GaugeZ owns rather than
/// borrows: one the user pastes into Settings or exports as `OLLAMA_API_KEY`.
actor OllamaUsageProvider: UsageProviding {
    private let session: URLSession
    private let retryPolicy: ProviderRetryPolicy
    private let loadKey: @Sendable () -> String?

    init(session: URLSession? = nil, retryPolicy: ProviderRetryPolicy? = nil,
         loadKey: @escaping @Sendable () -> String? = { OwnedAPIKey.ollama.load() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = session ?? URLSession(configuration: configuration)
        self.retryPolicy = retryPolicy ?? ProviderRetryPolicy(provider: .ollama)
        self.loadKey = loadKey
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        // Re-read on every fetch: the key can be replaced or removed in Settings at any time.
        guard let key = loadKey() else { throw OllamaProviderError.noKey }

        var request = URLRequest(url: OllamaUsageParser.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GaugeZ/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OllamaProviderError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw OllamaProviderError.malformed }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw OllamaProviderError.unauthorized
        case 429: throw retryPolicy.throttled(response: http)
        case 500...599: throw OllamaProviderError.server(http.statusCode)
        default: throw OllamaProviderError.unexpectedStatus(http.statusCode)
        }

        let windows = try OllamaUsageParser.windows(from: data)
        retryPolicy.succeeded()
        return UsageSnapshot(
            provider: .ollama,
            accountID: nil,
            planName: "Ollama Cloud",
            windows: windows,
            observedAt: .now,
            source: "Ollama API key · ollama.com usage",
            health: .live
        )
    }
}

/// Parses `GET https://ollama.com/api/usage`.
///
/// Current plans return one monthly window, legacy ones a session and a weekly window:
/// `{"limits":{"monthly":{"usage":0.152,"models":[…]}}}`. `usage` is a *fraction* of the plan's
/// allowance — 0.152 is 15.2% — not dollars, so the tier does not change the reading. The API
/// exposes only a rolling activity period, never the billing cycle, so no window carries a reset:
/// showing one would be a guess. The per-model `models` rows are bare request counts with no
/// limit, which a percent ring cannot express, so they are left out.
enum OllamaUsageParser {
    static let endpoint = URL(string: "https://ollama.com/api/usage")!

    private static let descriptors: [(key: String, id: String, minutes: Int?)] = [
        ("monthly", "monthly", 43_200),
        ("session", "session", nil),
        ("weekly", "weekly", 10_080)
    ]

    private static func label(for id: String) -> String {
        switch id {
        case "monthly": String(localized: "Monthly limit", bundle: .language)
        case "weekly": String(localized: "Weekly limit", bundle: .language)
        default: String(localized: "Session limit", bundle: .language)
        }
    }

    static func windows(from data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["limits"] as? [String: Any]
        else { throw OllamaProviderError.malformed }

        var windows: [UsageWindow] = []
        for descriptor in descriptors {
            guard let entry = limits[descriptor.key] as? [String: Any] else { continue }
            // A window that is present but unreadable is malformed data, never an unused quota;
            // a usage of exactly 0 is a real reading and is kept.
            guard let usage = (entry["usage"] as? NSNumber)?.doubleValue, usage.isFinite, usage >= 0 else {
                throw OllamaProviderError.malformed
            }
            windows.append(UsageWindow(
                id: descriptor.id,
                label: label(for: descriptor.id),
                usedPercent: min(100, usage * 100),
                resetsAt: nil,
                durationMinutes: descriptor.minutes
            ))
        }
        guard !windows.isEmpty else { throw OllamaProviderError.noLimits }
        return windows
    }
}

enum OllamaProviderError: LocalizedError, ProviderHealthDescribing {
    case noKey
    case unauthorized
    case offline(String)
    case server(Int)
    case unexpectedStatus(Int)
    case malformed
    case noLimits

    var errorDescription: String? {
        switch self {
        case .noKey: String(localized: "No Ollama API key. Add one in Settings, or export OLLAMA_API_KEY.", bundle: .language)
        case .unauthorized: String(localized: "Ollama rejected the API key. Add a new one in Settings.", bundle: .language)
        case .offline(let detail): String(localized: "Ollama could not be reached: \(detail)", bundle: .language)
        case .server(let status): String(localized: "Ollama returned a server error (\(status)).", bundle: .language)
        case .unexpectedStatus(let status): String(localized: "Ollama returned an unexpected response (\(status)).", bundle: .language)
        case .malformed: String(localized: "Ollama returned an unsupported usage response.", bundle: .language)
        case .noLimits: String(localized: "Ollama reported no usage limits on this key.", bundle: .language)
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? String(localized: "Ollama unavailable", bundle: .language)
        switch self {
        case .noKey, .unauthorized: return .signedOut(message)
        case .offline, .server: return .stale(message)
        case .unexpectedStatus, .malformed, .noLimits: return .unavailable(message)
        }
    }
}
