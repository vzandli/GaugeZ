// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import Foundation
import SQLite3

/// Reads Devin (formerly Windsurf) plan usage through the same GetUserStatus call the editor makes.
///
/// The session comes from whichever tool owns the sign-in: Devin Desktop's local state database
/// first, then the CLI's `credentials.toml`. GaugeZ only borrows it — never refreshes, writes or
/// logs it. The quota cached inside the Desktop database can lag the account, so every refresh
/// asks the service instead of reading that cache.
actor DevinUsageProvider: UsageProviding {
    private let session: URLSession
    private let retryPolicy: ProviderRetryPolicy
    private let loadCredentials: @Sendable () throws -> DevinLocalSession

    init(session: URLSession? = nil, retryPolicy: ProviderRetryPolicy? = nil,
         loadCredentials: @escaping @Sendable () throws -> DevinLocalSession = { try DevinLocalSession.load() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // The key travels in the request body, so a redirect to another host would hand it away.
        self.session = session ?? URLSession(configuration: configuration,
                                             delegate: DevinRedirectBlock(), delegateQueue: nil)
        self.retryPolicy = retryPolicy ?? ProviderRetryPolicy(provider: .devin)
        self.loadCredentials = loadCredentials
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        // Re-read every time: ordinary local files, so no prompt, and the key rotates on sign-in.
        let credential = try loadCredentials()

        var request = URLRequest(url: DevinUsageParser.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Connect's unary-over-JSON handshake. Without it the service answers with a gRPC frame.
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("GaugeZ/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["apiKey": credential.apiKey, "ideName": "windsurf", "ideVersion": "1.108.2",
                         "extensionName": "windsurf", "extensionVersion": "1.108.2", "locale": "en"]
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DevinProviderError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DevinProviderError.malformed }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw DevinProviderError.unauthorized
        case 403: throw DevinProviderError.accessDenied
        case 429: throw retryPolicy.throttled(response: http)
        case 500...599: throw DevinProviderError.server(http.statusCode)
        default: throw DevinProviderError.unexpectedStatus(http.statusCode)
        }

        let windows = try DevinUsageParser.windows(from: data)
        retryPolicy.succeeded()
        return UsageSnapshot(
            provider: .devin,
            accountID: credential.email,
            planName: nil,
            windows: windows,
            observedAt: .now,
            source: credential.source,
            health: .live
        )
    }
}

/// Devin's own redirects stay inside its API; anything else would forward the borrowed key.
private final class DevinRedirectBlock: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Local session

/// The session Devin keeps for itself: the Desktop app's state database, or the CLI's TOML file.
struct DevinLocalSession: Sendable {
    let apiKey: String
    let email: String?
    let source: String

    static var stateDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
    }

    static var cliCredentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/devin/credentials.toml")
    }

    static func load() throws -> DevinLocalSession {
        try load(stateDatabase: stateDatabaseURL, cliCredentials: cliCredentialsURL)
    }

    /// Desktop first. The CLI file is only reached when the database has nothing to borrow,
    /// so a Mac with both cannot flip between accounts depending on read order.
    static func load(stateDatabase: URL, cliCredentials: URL) throws -> DevinLocalSession {
        if let desktop = loadDesktop(from: stateDatabase) { return desktop }
        guard let cli = loadCLI(from: cliCredentials) else { throw DevinProviderError.notSignedIn }
        return cli
    }

    /// Devin Desktop stores its auth as JSON under `ItemTable.key = "windsurfAuthStatus"`,
    /// the VS Code key/value table. Opened read-only through `ReadOnlySQLite` so a running
    /// editor's WAL is honored and a quit one still reads.
    static func loadDesktop(from url: URL) -> DevinLocalSession? {
        guard FileManager.default.fileExists(atPath: url.path),
              let db = ReadOnlySQLite.open(path: url.path) else { return nil }
        defer { sqlite3_close(db) }
        let rows = ReadOnlySQLite.rows(
            in: db, sql: "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1", columns: 1)
        guard let json = rows.first?.first,
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let key = headerSafe(root["apiKey"]) else { return nil }
        let email = (root["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return DevinLocalSession(apiKey: key, email: email,
                                 source: String(localized: "Devin Desktop sign-in", bundle: .language))
    }

    /// `devin auth login` writes a small TOML file; only `windsurf_api_key` is needed, so a
    /// TOML parser is not warranted.
    static func loadCLI(from url: URL) -> DevinLocalSession? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("windsurf_api_key")
        }), let quoted = line.split(separator: "\"").dropFirst().first,
            let key = headerSafe(String(quoted)) else { return nil }
        return DevinLocalSession(apiKey: key, email: nil,
                                 source: String(localized: "Devin CLI sign-in", bundle: .language))
    }

    /// Non-empty single-line strings only: an empty key cannot succeed, and a key carrying a
    /// line break would be an injection into the request this app builds.
    private static func headerSafe(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.rangeOfCharacter(from: .newlines) == nil, text.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return text
    }
}

// MARK: - Parsing

/// `POST …/SeatManagementService/GetUserStatus`, answered as protobuf JSON:
/// `{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":…,"dailyQuotaResetAtUnix":"…"}}}`.
///
/// Two protobuf habits shape the parser: 64-bit fields arrive as strings, and a field at its
/// default value is omitted. The second one matters — the service drops
/// `*QuotaRemainingPercent` once it reaches 0, leaving the reset timestamp as the only sign the
/// quota is still metered. A missing percent beside a reset is therefore fully used, not
/// unmetered; with neither present there is no reading and the row is skipped.
enum DevinUsageParser {
    static let endpoint = URL(string: "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")!

    private static let descriptors: [(id: String, label: String, hidden: String, minutes: Int)] = [
        ("daily", String(localized: "Daily limit", bundle: .language), "hideDailyQuota", 1_440),
        ("weekly", String(localized: "Weekly limit", bundle: .language), "hideWeeklyQuota", 10_080)
    ]

    static func windows(from data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["userStatus"] as? [String: Any],
              let plan = user["planStatus"] as? [String: Any]
        else { throw DevinProviderError.malformed }

        var windows: [UsageWindow] = []
        for descriptor in descriptors {
            guard plan[descriptor.hidden] as? Bool != true else { continue }
            let resetsAt = number(plan["\(descriptor.id)QuotaResetAtUnix"])
                .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            let remaining: Double
            if let reported = number(plan["\(descriptor.id)QuotaRemainingPercent"]) {
                guard (0...100).contains(reported) else { throw DevinProviderError.malformed }
                remaining = reported
            } else if resetsAt != nil {
                remaining = 0
            } else {
                continue
            }
            windows.append(UsageWindow(
                id: descriptor.id,
                label: descriptor.label,
                usedPercent: 100 - remaining,
                resetsAt: resetsAt,
                durationMinutes: descriptor.minutes
            ))
        }
        guard !windows.isEmpty else { throw DevinProviderError.noLimits }
        return windows
    }

    /// Booleans are `NSNumber`s too, and a JSON `true` must never read as the number 1.
    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            result = number.doubleValue
        } else {
            result = (value as? String).flatMap(Double.init)
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
}

enum DevinProviderError: LocalizedError, ProviderHealthDescribing {
    case notSignedIn
    case unauthorized
    case accessDenied
    case offline(String)
    case server(Int)
    case unexpectedStatus(Int)
    case malformed
    case noLimits

    var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "Devin is not signed in. Sign in inside Devin, or run devin auth login, then retry.", bundle: .language)
        case .unauthorized: String(localized: "Devin rejected the local sign-in. Sign in inside Devin again.", bundle: .language)
        case .accessDenied: String(localized: "This Devin account has no plan usage to read.", bundle: .language)
        case .offline(let detail): String(localized: "Devin could not be reached: \(detail)", bundle: .language)
        case .server(let status): String(localized: "Devin returned a server error (\(status)).", bundle: .language)
        case .unexpectedStatus(let status): String(localized: "Devin returned an unexpected response (\(status)).", bundle: .language)
        case .malformed: String(localized: "Devin returned an unsupported usage response.", bundle: .language)
        case .noLimits: String(localized: "Devin reports no metered quota for this plan.", bundle: .language)
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? String(localized: "Devin unavailable", bundle: .language)
        switch self {
        case .notSignedIn, .unauthorized: return .signedOut(message)
        case .offline, .server: return .stale(message)
        case .accessDenied, .unexpectedStatus, .malformed, .noLimits: return .unavailable(message)
        }
    }
}
