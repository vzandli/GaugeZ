import Foundation
import SQLite3

/// Reads Cursor plan usage through the dashboard endpoints Cursor's own usage page calls.
///
/// The session comes from the signed-in Cursor app: its access token lives in Cursor's local
/// state database next to the cached account email. GaugeZ keeps the token in memory for one
/// request and never persists or logs it. Cursor's dashboard endpoints are not a documented
/// contract, so the parser is strict and any shape change surfaces as "unavailable" rather
/// than as a guessed number.
actor CursorUsageProvider: UsageProviding {
    static let applicationBundlePath = "/Applications/Cursor.app"
    private static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let legacyUsageURL = URL(string: "https://cursor.com/api/usage")!

    private let session: URLSession
    private let retryPolicy = ProviderRetryPolicy(provider: .cursor)

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        let snapshot = try await fetchUsage()
        retryPolicy.succeeded()
        return snapshot
    }

    private func fetchUsage() async throws -> UsageSnapshot {
        let cursorSession = try CursorLocalSession.load()
        if let expiresAt = cursorSession.expiresAt, expiresAt < .now {
            throw CursorProviderError.sessionExpired
        }

        let source = "Cursor \(cursorSession.appVersion ?? "") session".replacingOccurrences(of: "  ", with: " ")
        let summaryData = try await request(Self.summaryURL, session: cursorSession)
        do {
            return try CursorUsageParser.snapshot(
                fromSummary: summaryData,
                account: cursorSession.email,
                membership: cursorSession.membershipType,
                source: source
            )
        } catch CursorProviderError.unsupportedSummary {
            // Older accounts may still be served by the request-count endpoint.
            var components = URLComponents(url: Self.legacyUsageURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "user", value: cursorSession.userID)]
            let legacyData = try await request(components.url!, session: cursorSession)
            return try CursorUsageParser.snapshot(
                fromLegacyUsage: legacyData,
                account: cursorSession.email,
                membership: cursorSession.membershipType,
                source: source
            )
        }
    }

    private func request(_ url: URL, session cursorSession: CursorLocalSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(cursorSession.cookieValue)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("GaugeZ/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CursorProviderError.offline(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw CursorProviderError.malformedResponse }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw CursorProviderError.unauthorized
        case 429: throw retryPolicy.throttled(response: http)
        case 500...599: throw CursorProviderError.server(http.statusCode)
        default: throw CursorProviderError.unexpectedStatus(http.statusCode)
        }
    }
}

// MARK: - Local session

struct CursorLocalSession {
    let accessToken: String
    let userID: String
    let email: String?
    let membershipType: String?
    let expiresAt: Date?
    let appVersion: String?

    /// Cursor's dashboard expects `<user id>::<access token>` in its session cookie.
    var cookieValue: String { "\(userID)%3A%3A\(accessToken)" }

    static var stateDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static func load() throws -> CursorLocalSession {
        guard FileManager.default.fileExists(atPath: CursorUsageProvider.applicationBundlePath) else {
            throw CursorProviderError.notInstalled
        }
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            throw CursorProviderError.notSignedIn
        }

        let store = try CursorStateStore(path: stateDatabaseURL.path)
        defer { store.close() }

        guard let token = store.value(forKey: "cursorAuth/accessToken"), !token.isEmpty else {
            throw CursorProviderError.notSignedIn
        }
        let claims = try Self.claims(fromJWT: token)
        guard let subject = claims["sub"] as? String,
              let userID = subject.split(separator: "|").last.map(String.init), !userID.isEmpty
        else { throw CursorProviderError.malformedSession }

        let expiresAt = (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return CursorLocalSession(
            accessToken: token,
            userID: userID,
            email: store.value(forKey: "cursorAuth/cachedEmail"),
            membershipType: store.value(forKey: "cursorAuth/stripeMembershipType"),
            expiresAt: expiresAt,
            appVersion: Self.installedVersion()
        )
    }

    static func claims(fromJWT token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { throw CursorProviderError.malformedSession }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CursorProviderError.malformedSession }
        return object
    }

    private static func installedVersion() -> String? {
        let plist = URL(fileURLWithPath: CursorUsageProvider.applicationBundlePath)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }
}

/// Minimal read-only reader for the VS Code style key/value table Cursor keeps its auth state in.
private final class CursorStateStore {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CursorProviderError.stateUnreadable
        }
        handle = db
    }

    func value(forKey key: String) -> String? {
        guard let handle else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: text)
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
        }
        handle = nil
    }
}

// MARK: - Parsing

enum CursorUsageParser {
    /// `GET /api/usage-summary`: plan allowance for the current billing cycle plus on-demand spend.
    static func snapshot(fromSummary data: Data, account: String?, membership: String?, source: String) throws -> UsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorProviderError.malformedResponse
        }
        guard let individual = object["individualUsage"] as? [String: Any],
              let plan = individual["plan"] as? [String: Any]
        else { throw CursorProviderError.unsupportedSummary }

        let cycleEnd = (object["billingCycleEnd"] as? String).flatMap(parseDate)
        let membershipType = object["membershipType"] as? String ?? membership
        var windows: [UsageWindow] = []

        if (plan["enabled"] as? Bool) != false {
            let unlimited = (object["isUnlimited"] as? Bool) ?? false
            if let percent = (plan["totalPercentUsed"] as? NSNumber)?.doubleValue {
                windows.append(try window(id: "cursor-plan", label: "Plan usage", usedPercent: percent, resetsAt: cycleEnd))
            } else if let used = (plan["used"] as? NSNumber)?.doubleValue,
                      let limit = (plan["limit"] as? NSNumber)?.doubleValue, limit > 0 {
                windows.append(try window(id: "cursor-plan", label: "Plan usage", usedPercent: used / limit * 100, resetsAt: cycleEnd))
            } else if !unlimited {
                throw CursorProviderError.malformedResponse
            }
        }

        if let onDemand = individual["onDemand"] as? [String: Any],
           (onDemand["enabled"] as? Bool) == true,
           let used = (onDemand["used"] as? NSNumber)?.doubleValue,
           let limit = (onDemand["limit"] as? NSNumber)?.doubleValue, limit > 0 {
            windows.append(try window(id: "cursor-on-demand", label: "On-demand spend", usedPercent: used / limit * 100, resetsAt: cycleEnd))
        }

        guard !windows.isEmpty else { throw CursorProviderError.unlimited }
        return UsageSnapshot(
            provider: .cursor,
            accountID: account,
            planName: membershipType.map { "Cursor \($0.capitalized)" },
            windows: windows,
            observedAt: .now,
            source: source,
            health: .live
        )
    }

    /// `GET /api/usage?user=`: the older request-count contract.
    static func snapshot(fromLegacyUsage data: Data, account: String?, membership: String?, source: String) throws -> UsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let premium = object["gpt-4"] as? [String: Any],
              let used = (premium["numRequests"] as? NSNumber)?.doubleValue
        else { throw CursorProviderError.malformedResponse }
        guard let limit = (premium["maxRequestUsage"] as? NSNumber)?.doubleValue, limit > 0 else {
            throw CursorProviderError.unlimited
        }

        var resetsAt: Date?
        if let start = (object["startOfMonth"] as? String).flatMap(parseDate) {
            resetsAt = Calendar.current.date(byAdding: .month, value: 1, to: start)
        }
        let window = try window(id: "cursor-premium-requests", label: "Premium requests", usedPercent: used / limit * 100, resetsAt: resetsAt)
        return UsageSnapshot(
            provider: .cursor,
            accountID: account,
            planName: membership.map { "Cursor \($0.capitalized)" },
            windows: [window],
            observedAt: .now,
            source: source,
            health: .live
        )
    }

    private static func window(id: String, label: String, usedPercent: Double, resetsAt: Date?) throws -> UsageWindow {
        guard usedPercent.isFinite, usedPercent >= 0 else { throw CursorProviderError.malformedResponse }
        return UsageWindow(
            id: id,
            label: label,
            usedPercent: Int(min(100, usedPercent).rounded()),
            resetsAt: resetsAt,
            durationMinutes: nil
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        if let millis = Double(value), millis > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        return nil
    }
}

enum CursorProviderError: LocalizedError, ProviderHealthDescribing {
    case notInstalled
    case notSignedIn
    case stateUnreadable
    case malformedSession
    case sessionExpired
    case unauthorized
    case rateLimited
    case offline(String)
    case server(Int)
    case unexpectedStatus(Int)
    case malformedResponse
    case unsupportedSummary
    case unlimited

    var errorDescription: String? {
        switch self {
        case .notInstalled: "Cursor is not installed."
        case .notSignedIn: "Cursor is not signed in. Sign in inside Cursor, then refresh."
        case .stateUnreadable: "Cursor's local state could not be read."
        case .malformedSession: "Cursor's sign-in has an unsupported format."
        case .sessionExpired: "Cursor's sign-in has expired. Open Cursor so it refreshes, then retry."
        case .unauthorized: "Cursor rejected the local sign-in. Sign in inside Cursor again."
        case .rateLimited: "Cursor asked GaugeZ to slow down."
        case .offline(let detail): "Cursor could not be reached: \(detail)"
        case .server(let status): "Cursor returned a server error (\(status))."
        case .unexpectedStatus(let status): "Cursor returned an unexpected response (\(status))."
        case .malformedResponse: "Cursor returned an unsupported usage response. Open the Cursor dashboard instead."
        case .unsupportedSummary: "Cursor's usage summary changed shape."
        case .unlimited: "Cursor reports no usage limit for this plan."
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? "Unknown Cursor error"
        switch self {
        case .notSignedIn, .sessionExpired, .unauthorized: return .signedOut(message)
        case .rateLimited, .offline, .server: return .stale(message)
        default: return .unavailable(message)
        }
    }
}
