// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import Foundation

/// Which MiniMax console a key belongs to. The two regions do not share accounts: a China key
/// asked of api.minimax.io answers as an auth failure, which would read as a signed-out plan
/// that is merely pointed at the other country.
enum MiniMaxRegion: String, CaseIterable, Identifiable, Sendable {
    /// api.minimax.io / platform.minimax.io
    case global
    /// api.minimaxi.com / platform.minimaxi.com
    case china

    var id: String { rawValue }

    var label: String {
        switch self {
        case .global: String(localized: "Global", bundle: .language)
        case .china: String(localized: "China", bundle: .language)
        }
    }

    var apiBase: URL {
        switch self {
        case .global: URL(string: "https://api.minimax.io")!
        case .china: URL(string: "https://api.minimaxi.com")!
        }
    }

    /// Token Plan is the current product; Coding Plan is the older prompt-count one. Both are
    /// asked in turn, because a key entitled to one 404s on the other's path.
    var remainsURLs: [URL] {
        [apiBase.appending(path: "v1/token_plan/remains"),
         apiBase.appending(path: "v1/api/openplatform/coding_plan/remains")]
    }
}

/// Reads MiniMax Coding Plan / Token Plan usage from MiniMax's own remains endpoints, with the
/// key the user pasted in Settings. Only that key: Codenotch also drove a console cookie and an
/// embedded WebView login, and GaugeZ borrows credentials rather than creating them.
actor MiniMaxUsageProvider: UsageProviding {
    private let session: URLSession
    private let retryPolicy: ProviderRetryPolicy
    private let loadAPIKey: @Sendable () -> String?
    /// Re-read on every fetch so a region change in Settings applies without a restart.
    private let resolveRegion: @Sendable () -> MiniMaxRegion

    init(session: URLSession? = nil, retryPolicy: ProviderRetryPolicy? = nil,
         loadAPIKey: @escaping @Sendable () -> String? = { OwnedAPIKey.minimax.load() },
         resolveRegion: @escaping @Sendable () -> MiniMaxRegion = {
             MiniMaxRegion(rawValue: UserDefaults.standard.string(forKey: "minimaxRegion") ?? "") ?? .global
         }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = session ?? URLSession(configuration: configuration)
        self.retryPolicy = retryPolicy ?? ProviderRetryPolicy(provider: .minimax)
        self.loadAPIKey = loadAPIKey
        self.resolveRegion = resolveRegion
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        let raw = loadAPIKey()
        guard let pasted = OwnedAPIKey.headerSafe(raw) else { throw MiniMaxProviderError.notSignedIn }
        // A pay-as-you-go `sk-api-` key is not a plan token: MiniMax will not meter it here, and
        // reporting that as a rejected key would send the user to re-paste a perfectly good key.
        guard let token = MiniMaxUsageParser.codingPlanToken(from: pasted) else {
            throw MiniMaxProviderError.payAsYouGoKey
        }

        let region = resolveRegion()
        var sawUnreadable = false
        var lastStatus = 0
        for url in region.remainsURLs {
            let data: Data
            switch try await remains(at: url, token: token) {
            case .body(let body): data = body
            case .missingEndpoint(let status): lastStatus = status; continue
            }
            do {
                let reading = try MiniMaxUsageParser.reading(from: data, now: .now)
                retryPolicy.succeeded()
                return UsageSnapshot(
                    provider: .minimax,
                    accountID: nil,
                    planName: reading.plan,
                    windows: reading.windows,
                    observedAt: .now,
                    source: "MiniMax key · \(region.label) · Coding Plan remains",
                    health: .live
                )
            } catch MiniMaxProviderError.noLimits, MiniMaxProviderError.malformed {
                // Not this product's body. Worth asking the other remains path before giving up.
                sawUnreadable = true
            }
        }
        if sawUnreadable { throw MiniMaxProviderError.noLimits }
        throw lastStatus == 0 ? MiniMaxProviderError.malformed : MiniMaxProviderError.unexpectedStatus(lastStatus)
    }

    private enum RemainsAnswer {
        case body(Data)
        case missingEndpoint(Int)
    }

    private func remains(at url: URL, token: String) async throws -> RemainsAnswer {
        var request = URLRequest(url: url)
        // POST 404s on these paths; MiniMax's own docs call GET.
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
            throw MiniMaxProviderError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MiniMaxProviderError.malformed }

        // MiniMax rides its real answer in `base_resp.status_code` under HTTP 200, so the
        // envelope is read before the status is believed.
        let envelope = MiniMaxUsageParser.envelopeStatus(in: data)
        if MiniMaxUsageParser.isRateLimited(status: http.statusCode, envelope: envelope) {
            throw http.statusCode == 429 ? retryPolicy.throttled(response: http) : retryPolicy.throttled(retryAfter: nil)
        }
        if MiniMaxUsageParser.isDeadCredential(status: http.statusCode, envelope: envelope) {
            throw MiniMaxProviderError.unauthorized
        }
        // 1004 on a bearer request is this host wanting a console session, not a dead key: the
        // other remains path is the one that takes the key.
        if MiniMaxUsageParser.isMissingEndpoint(status: http.statusCode, envelope: envelope) {
            return .missingEndpoint(http.statusCode)
        }
        switch http.statusCode {
        case 200..<300: return .body(data)
        case 500...599: throw MiniMaxProviderError.server(http.statusCode)
        default: throw MiniMaxProviderError.unexpectedStatus(http.statusCode)
        }
    }
}

/// Parses MiniMax remains JSON. `GET /v1/token_plan/remains` and the older
/// `/v1/api/openplatform/coding_plan/remains` share one `model_remains` array:
///
/// ```json
/// { "base_resp": { "status_code": 0 },
///   "current_subscribe_title": "Max",
///   "model_remains": [
///     { "model_name": "general", "current_interval_total_count": 1000,
///       "current_interval_usage_count": 250, "start_time": 1700000000000,
///       "end_time": 1700018000000 } ] }
/// ```
///
/// `current_interval_usage_count` is *remaining*, not used — used is `total - remaining`. Token
/// Plan rows leave the counts at 0 and answer `*_remaining_percent` instead, where used percent
/// is `100 - remaining`.
enum MiniMaxUsageParser {
    struct Reading: Sendable {
        let plan: String?
        let windows: [UsageWindow]
    }

    static func reading(from data: Data, now: Date = .now) throws -> Reading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiniMaxProviderError.malformed
        }
        let payload = unwrap(root)
        if let failure = envelopeFailure(in: root, payload: payload) { throw failure }
        let windows = windows(in: payload, now: now)
        guard !windows.isEmpty else { throw MiniMaxProviderError.noLimits }
        return Reading(plan: string(payload["current_subscribe_title"])
            ?? string(payload["plan_name"]) ?? string(payload["combo_title"]), windows: windows)
    }

    /// Pay-as-you-go `sk-api-` keys cannot query plan remains. `sk-cp-` and any unrecognised
    /// prefix still can, so only that one prefix is refused.
    static func codingPlanToken(from apiKey: String?) -> String? {
        guard var raw = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("bearer ") {
            raw = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !raw.isEmpty, !raw.lowercased().hasPrefix("sk-api-") else { return nil }
        return raw
    }

    static func envelopeStatus(in data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let code = int(root["status_code"]) ?? int(root["code"]) { return code }
        let resp = (root["base_resp"] as? [String: Any])
            ?? ((root["data"] as? [String: Any])?["base_resp"] as? [String: Any])
        guard let resp else { return nil }
        return int(resp["status_code"]) ?? int(resp["code"])
    }

    /// 2045 is MiniMax's "overloaded", which rides under HTTP 200 the same way 1004 does.
    static func isRateLimited(status: Int, envelope: Int?) -> Bool {
        status == 429 || envelope == 429 || envelope == 2045
    }

    static func isDeadCredential(status: Int, envelope: Int?) -> Bool {
        status == 401 || status == 403 || envelope == 401 || envelope == 403
    }

    static func isMissingEndpoint(status: Int, envelope: Int?) -> Bool {
        status == 404 || status == 405 || envelope == 1004
    }

    // MARK: - Private

    /// `data` is the payload when present; the plan name and `model_remains` live in either the
    /// wrapper or the inner object, so inner keys win and outer ones fill the gaps.
    private static func unwrap(_ root: [String: Any]) -> [String: Any] {
        guard let inner = root["data"] as? [String: Any] else { return root }
        var merged = root
        for (key, value) in inner { merged[key] = value }
        if merged["base_resp"] == nil { merged["base_resp"] = root["base_resp"] }
        return merged
    }

    /// A non-zero `base_resp.status_code` is a business error, not an empty reading: HTTP 200
    /// with 1004 is a missing session. Both envelopes are read, and auth wins.
    private static func envelopeFailure(in root: [String: Any], payload: [String: Any]) -> MiniMaxProviderError? {
        var fallback: MiniMaxProviderError?
        for resp in [payload["base_resp"] as? [String: Any], root["base_resp"] as? [String: Any]] {
            guard let resp, let code = int(resp["status_code"]) ?? int(resp["code"]), code != 0, code != 200 else { continue }
            let message = (string(resp["status_msg"]) ?? string(resp["msg"]))?.lowercased() ?? ""
            if code == 401 || code == 403 || message.contains("unauthorized") { return .unauthorized }
            if code == 1004 { return .malformed }
            if fallback == nil { fallback = .unexpectedStatus(code) }
        }
        return fallback
    }

    private static let descriptors: [(id: String, label: String, minutes: Int, weekly: Bool)] = [
        ("session", String(localized: "5-hour limit", bundle: .language), 300, false),
        ("weekly", String(localized: "Weekly limit", bundle: .language), 10_080, true)
    ]

    private static func windows(in payload: [String: Any], now: Date) -> [UsageWindow] {
        let lanes = (payload["model_remains"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        for lane in lanes.sorted(by: laneOrder) {
            // Video / speech / image rows are not the coding ring, even when they sit first and
            // report 100% remaining.
            guard isTextLane(string(lane["model_name"])) else { continue }
            let windows = descriptors.compactMap {
                window(id: $0.id, label: $0.label, minutes: $0.minutes,
                       meter: meter(lane, weekly: $0.weekly), weekly: $0.weekly, now: now)
            }
            if !windows.isEmpty { return windows }
        }
        return []
    }

    /// General first, so a video placeholder at the head of `model_remains` cannot become the ring.
    private static func laneOrder(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        func rank(_ lane: [String: Any]) -> Int {
            let name = string(lane["model_name"])?.lowercased() ?? ""
            if name == "general" { return 0 }
            return isTextLane(name) ? 1 : 2
        }
        return rank(a) < rank(b)
    }

    /// Unnamed remains are the coding-plan text quota — older answers omit `model_name`.
    private static func isTextLane(_ name: String?) -> Bool {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return true }
        let name = raw.lowercased()
        return name == "general" || name == "text generation" || name == "text-generation"
            || name.contains("minimax-m") || name.hasPrefix("m2.")
    }

    private struct Meter {
        let total: Int?
        let remaining: Int?
        let remainingPercent: Double?
        let status: Int?
        let start: Double?
        let end: Double?
        let remainsTime: Double?
    }

    private static func meter(_ lane: [String: Any], weekly: Bool) -> Meter {
        if weekly {
            return Meter(total: int(lane["current_weekly_total_count"]),
                         remaining: int(lane["current_weekly_usage_count"]),
                         remainingPercent: number(lane["current_weekly_remaining_percent"]),
                         status: int(lane["current_weekly_status"]),
                         start: number(lane["weekly_start_time"]),
                         end: number(lane["weekly_end_time"]),
                         remainsTime: number(lane["weekly_remains_time"]))
        }
        return Meter(total: int(lane["current_interval_total_count"]),
                     remaining: int(lane["current_interval_usage_count"]),
                     remainingPercent: number(lane["current_interval_remaining_percent"]),
                     status: int(lane["current_interval_status"]),
                     start: number(lane["start_time"]),
                     end: number(lane["end_time"]),
                     remainsTime: number(lane["remains_time"]))
    }

    private static func window(id: String, label: String, minutes: Int,
                               meter: Meter, weekly: Bool, now: Date) -> UsageWindow? {
        // Status 3 with zeros and 100% remaining is a schema row, not a quota. Unlimited weekly
        // on the text lane is the one status-3 reading that is real.
        let unlimited = weekly && meter.status == 3 && (meter.remainingPercent.map { $0 >= 100 } ?? false)
        if !unlimited, isPlaceholder(meter) { return nil }

        let duration = self.minutes(start: meter.start, end: meter.end) ?? minutes
        if unlimited {
            return UsageWindow(id: id, label: label, usedPercent: 0, resetsAt: nil, durationMinutes: duration)
        }
        let resetsAt = reset(end: meter.end, remains: meter.remainsTime, now: now)

        if let remainingPercent = meter.remainingPercent {
            // Remaining can exceed 100 while a boost is active; a negative used percent would
            // draw as a ring of leftover quota.
            return UsageWindow(id: id, label: label, usedPercent: min(100, max(0, 100 - remainingPercent)),
                               resetsAt: resetsAt, durationMinutes: duration)
        }
        guard let total = meter.total, total > 0, let remaining = meter.remaining else { return nil }
        let used = Double(max(0, total - remaining)) / Double(total) * 100
        return UsageWindow(id: id, label: label, usedPercent: min(100, used),
                           resetsAt: resetsAt, durationMinutes: duration)
    }

    private static func isPlaceholder(_ meter: Meter) -> Bool {
        meter.status == 3 && (meter.total ?? 0) == 0 && (meter.remaining ?? 0) == 0
            && (meter.remainingPercent.map { $0 >= 100 } ?? false)
    }

    private static func minutes(start: Double?, end: Double?) -> Int? {
        guard let start = date(fromEpoch: start), let end = date(fromEpoch: end) else { return nil }
        let length = end.timeIntervalSince(start) / 60
        return length > 0 ? Int(length.rounded()) : nil
    }

    /// `end_time` is an epoch; a past end is stale, so `remains_time` — always a millisecond
    /// duration rather than an epoch — is the fallback.
    private static func reset(end: Double?, remains: Double?, now: Date) -> Date? {
        if let end = date(fromEpoch: end), end > now { return end }
        guard let remains, remains > 0 else { return nil }
        return now.addingTimeInterval(remains / 1000)
    }

    private static func date(fromEpoch value: Double?) -> Date? {
        guard let value, value > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }

    private static func number(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return number.doubleValue }
        if let text = any as? String { return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func int(_ any: Any?) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        if let text = any as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed) ?? Double(trimmed).map(Int.init)
        }
        return nil
    }

    private static func string(_ any: Any?) -> String? {
        guard let text = any as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum MiniMaxProviderError: LocalizedError, ProviderHealthDescribing {
    case notSignedIn
    case payAsYouGoKey
    case unauthorized
    case offline(String)
    case server(Int)
    case unexpectedStatus(Int)
    case malformed
    case noLimits

    var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "Add a MiniMax Coding Plan key in Settings.", bundle: .language)
        case .payAsYouGoKey: String(localized: "This is a pay-as-you-go MiniMax key. Add a Coding Plan key instead.", bundle: .language)
        case .unauthorized: String(localized: "MiniMax rejected the key. Check the key and the region in Settings.", bundle: .language)
        case .offline(let detail): String(localized: "MiniMax could not be reached: \(detail)", bundle: .language)
        case .server(let status): String(localized: "MiniMax returned a server error (\(status)).", bundle: .language)
        case .unexpectedStatus(let status): String(localized: "MiniMax returned an unexpected response (\(status)).", bundle: .language)
        case .malformed: String(localized: "MiniMax returned an unsupported usage response.", bundle: .language)
        case .noLimits: String(localized: "MiniMax reported no usage windows.", bundle: .language)
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? String(localized: "MiniMax unavailable", bundle: .language)
        switch self {
        case .notSignedIn, .unauthorized: return .signedOut(message)
        case .offline, .server: return .stale(message)
        case .payAsYouGoKey, .unexpectedStatus, .malformed, .noLimits: return .unavailable(message)
        }
    }
}
