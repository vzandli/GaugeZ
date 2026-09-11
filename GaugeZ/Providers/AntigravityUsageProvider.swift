import Foundation
import CoreFoundation

/// Reads Antigravity model quotas from the language server that a running Antigravity app or
/// Antigravity IDE hosts on 127.0.0.1.
///
/// Falls back to Google's quota endpoint using the stored Antigravity sign-in, then to
/// an explicitly derived local model-turn count when no quota is available.
actor AntigravityUsageProvider: UsageProviding {
    static let bundleIdentifiers = ["com.google.antigravity", "com.google.antigravity-ide"]
    private static let quotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let userStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"

    private let delegate = LocalhostTrustDelegate()
    private let session: URLSession

    private let localOverride: (@Sendable () async throws -> UsageSnapshot)?
    private let loadCredentials: @Sendable () throws -> AntigravityCredentials
    private let readActivity: @Sendable () -> AntigravityActivity
    init(remoteSession: URLSession = URLSession(configuration: .ephemeral),
         retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy(provider: .antigravity),
         localQuota: (@Sendable () async throws -> UsageSnapshot)? = nil,
         loadCredentials: @escaping @Sendable () throws -> AntigravityCredentials = { try AntigravityCredentials.load() },
         readActivity: @escaping @Sendable () -> AntigravityActivity = { AntigravityActivity.read() }) {
        self.remoteSession = remoteSession
        self.retryPolicy = retryPolicy
        self.localOverride = localQuota
        self.loadCredentials = loadCredentials
        self.readActivity = readActivity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    nonisolated func forgetCredentials() { AntigravityCredentials.forgetCached() }
    private let remoteSession: URLSession
    private let retryPolicy: ProviderRetryPolicy
    /// The access token Google last answered 403 for. A personal account is refused every time,
    /// so the endpoint is not asked again until Antigravity rotates the token, which is also
    /// the earliest moment a newly licensed account could answer differently.
    private var refusedToken: String?

    func fetchSnapshot() async throws -> UsageSnapshot {
        do {
            if let localOverride { return try await localOverride() }
            return try await fetchLocalSnapshot()
        }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            do { return try await fetchRemoteSnapshot() }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let activity = readActivity()
                guard activity.lastRequest != nil else { throw error }
                return UsageSnapshot(provider: .antigravity, accountID: nil, planName: nil, windows: [],
                                     observedAt: .now, source: "Derived from local transcripts · quota unavailable",
                                     health: .live, derivedRequestCount: activity.requestsToday)
            }
        }
    }

    private func fetchRemoteSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        let credentials = try loadCredentials()
        guard !credentials.isExpired else { throw SecretError.missing("Antigravity (sign-in expired)") }
        if credentials.accessToken == refusedToken { throw AntigravityProviderError.unexpectedStatus(403) }
        let host = credentials.isCLI ? "daily-cloudcode-pa.googleapis.com" : "cloudcode-pa.googleapis.com"
        var request = URLRequest(url: URL(string: "https://\(host)/v1internal:retrieveUserQuotaSummary")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: credentials.projectId.map { ["project": $0] } ?? [:])
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let (data, response) = try await remoteSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AntigravityProviderError.malformedResponse }
        if http.statusCode == 429 { throw retryPolicy.throttled(response: http) }
        if http.statusCode == 403 { refusedToken = credentials.accessToken }
        guard http.statusCode == 200 else { throw AntigravityProviderError.unexpectedStatus(http.statusCode) }
        refusedToken = nil
        let windows = try AntigravityQuotaParser.remoteWindows(from: data)
        retryPolicy.succeeded()
        return UsageSnapshot(provider: .antigravity, accountID: credentials.email, planName: credentials.authMethod,
                             windows: windows, observedAt: .now, source: "Google Cloud Code quota", health: .live)
    }

    private func fetchLocalSnapshot() async throws -> UsageSnapshot {
        let servers = try AntigravityProcessLocator.runningServers()
        guard !servers.isEmpty else {
            throw AntigravityProviderError.notRunning(installed: AntigravityProcessLocator.isInstalled)
        }

        var lastError: Error = AntigravityProviderError.noReachableServer
        for server in servers {
            let ports = try AntigravityProcessLocator.listeningPorts(pid: server.pid)
            for port in ports {
                for scheme in ["https", "http"] {
                    let endpoint = Endpoint(scheme: scheme, port: port, csrfToken: server.csrfToken)
                    do {
                        let summaryData = try await post(Self.quotaSummaryPath, body: ["forceRefresh": true], endpoint: endpoint)
                        let windows = try AntigravityQuotaParser.windows(fromQuotaSummary: summaryData)
                        let identity = try? await post(Self.userStatusPath, body: Self.metadataBody, endpoint: endpoint)
                        let account = identity.flatMap(AntigravityQuotaParser.identity(fromUserStatus:))
                        return UsageSnapshot(
                            provider: .antigravity,
                            accountID: account?.email,
                            planName: account?.plan,
                            windows: windows,
                            observedAt: .now,
                            source: "\(server.kind.displayName) language server",
                            health: .live
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                    }
                }
            }
        }
        throw lastError
    }

    private struct Endpoint {
        let scheme: String
        let port: Int
        let csrfToken: String
    }

    private static let metadataBody: [String: Any] = [
        "metadata": [
            "ideName": "antigravity",
            "extensionName": "antigravity",
            "ideVersion": "unknown",
            "locale": "en"
        ]
    ]

    private func post(_ path: String, body: [String: Any], endpoint: Endpoint) async throws -> Data {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)") else {
            throw AntigravityProviderError.noReachableServer
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AntigravityProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AntigravityProviderError.malformedResponse }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw AntigravityProviderError.rejected(http.statusCode)
        default: throw AntigravityProviderError.unexpectedStatus(http.statusCode)
        }
    }
}

/// Accepts the language server's self-signed certificate, but only for loopback hosts.
private final class LocalhostTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              ["127.0.0.1", "localhost"].contains(space.host.lowercased()),
              let trust = space.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - Process discovery

enum AntigravityProcessLocator {
    enum Kind {
        case app
        case ide

        var displayName: String {
            switch self {
            case .app: "Antigravity"
            case .ide: "Antigravity IDE"
            }
        }
    }

    struct Server {
        let pid: Int32
        let kind: Kind
        let csrfToken: String
    }

    static var isInstalled: Bool {
        ["/Applications/Antigravity.app", "/Applications/Antigravity IDE.app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Language servers launched by the Antigravity app or IDE, app first.
    static func runningServers() throws -> [Server] {
        let listing = try run("/bin/ps", ["-axo", "pid=,command="])
        return servers(fromProcessListing: listing)
    }

    static func servers(fromProcessListing listing: String) -> [Server] {
        var found: [Server] = []
        for line in listing.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let command = String(parts[1])
            guard let kind = kind(ofCommand: command) else { continue }
            guard let token = flagValue("--csrf_token", in: command) else { continue }
            found.append(Server(pid: pid, kind: kind, csrfToken: token))
        }
        return found.sorted { lhs, rhs in
            if lhs.kind == rhs.kind { return lhs.pid < rhs.pid }
            return lhs.kind == .app
        }
    }

    static func kind(ofCommand command: String) -> Kind? {
        let lower = command.lowercased()
        let isLanguageServer = lower.range(
            of: #"(^|/)language(?:_|-)server(?:[_-][a-z0-9]+)*(\s|$)"#,
            options: .regularExpression
        ) != nil
        guard isLanguageServer else { return nil }

        let ideMarkers = ["antigravity ide.app/", "--app_data_dir antigravity-ide", "--app_data_dir=antigravity-ide", "/extensions/antigravity/bin/language_server"]
        if ideMarkers.contains(where: lower.contains) { return .ide }
        let appMarkers = ["antigravity.app/", "/antigravity/"]
        if appMarkers.contains(where: lower.contains) || (lower.contains("--app_data_dir") && lower.contains("antigravity")) {
            return .app
        }
        return nil
    }

    static func listeningPorts(pid: Int32) throws -> [Int] {
        let output = try run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)], allowFailure: true)
        let regex = try NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#)
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports = Set<Int>()
        for match in regex.matches(in: output, range: range) {
            if let portRange = Range(match.range(at: 1), in: output), let port = Int(output[portRange]) {
                ports.insert(port)
            }
        }
        guard !ports.isEmpty else { throw AntigravityProviderError.noListeningPorts }
        return ports.sorted()
    }

    private static func flagValue(_ flag: String, in command: String) -> String? {
        let tokens = command.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() {
            if token == flag, index + 1 < tokens.count { return tokens[index + 1] }
            if token.hasPrefix(flag + "=") { return String(token.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard allowFailure || process.terminationStatus == 0 else {
            throw AntigravityProviderError.transport("\(executable) exited with status \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Parsing

enum AntigravityQuotaParser {
    struct Identity {
        let email: String?
        let plan: String?
    }

    /// Same parser for the local language server and Google's quota endpoint, so window IDs
    /// do not change depending on which answered.
    static func windows(fromQuotaSummary data: Data, now: Date = .now) throws -> [UsageWindow] {
        try windows(from: data, now: now)
    }

    static func remoteWindows(from data: Data, now: Date = .now) throws -> [UsageWindow] {
        try windows(from: data, now: now)
    }

    static func windows(from data: Data, now: Date = .now) throws -> [UsageWindow] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw AntigravityProviderError.malformedResponse
        }
        let groups = response.response?.groups
            ?? response.summary?.groups
            ?? response.groups
            ?? response.quotaGroups
            ?? []
        let parsed: [UsageWindow]
        if !groups.isEmpty {
            parsed = groupedWindows(groups)
        } else if let buckets = response.buckets, !buckets.isEmpty {
            parsed = buckets.contains(where: { $0.limit != nil })
                ? legacyWindows(buckets) : modelWindows(buckets, now: now)
        } else {
            parsed = []
        }
        guard !parsed.isEmpty else { throw AntigravityProviderError.noQuotaBuckets }
        return parsed
    }

    private struct Remaining: Decodable {
        let fraction: Double?

        private enum CodingKeys: String, CodingKey {
            case remainingFraction
            case oneofCase = "case"
            case value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let fraction = try container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
                self.fraction = fraction
            } else if try container.decodeIfPresent(String.self, forKey: .oneofCase) == "remainingFraction" {
                self.fraction = try container.decodeIfPresent(Double.self, forKey: .value)
            } else {
                self.fraction = nil
            }
        }
    }

    private struct Bucket: Decodable {
        let modelId: String?
        let bucketId: String?
        let name: String?
        let displayName: String?
        let remainingFraction: Double?
        let remaining: Remaining?
        let used: Double?
        let limit: Double?
        let resetTime: String?
        let window: String?
        let disabled: Bool?

        var fraction: Double? { remainingFraction ?? remaining?.fraction }
    }

    private struct Group: Decodable {
        let displayName: String?
        let buckets: [Bucket]?
    }

    private struct GroupBody: Decodable {
        let groups: [Group]?
    }

    private struct Response: Decodable {
        let buckets: [Bucket]?
        let groups: [Group]?
        let quotaGroups: [Group]?
        let response: GroupBody?
        let summary: GroupBody?
    }

    private struct Candidate {
        let remaining: Double
        let resetDate: Date?
        let isWeekly: Bool
    }

    private static func groupedWindows(_ groups: [Group]) -> [UsageWindow] {
        let sortedGroups = groups.enumerated().sorted { lhs, rhs in
            let lhsRank = groupRank(lhs.element.displayName)
            let rhsRank = groupRank(rhs.element.displayName)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }
        var windows: [UsageWindow] = []
        for indexedGroup in sortedGroups {
            windows.append(contentsOf: bucketWindows(in: indexedGroup.element))
        }
        return windows
    }

    private static func bucketWindows(in group: Group) -> [UsageWindow] {
        let sortedBuckets = (group.buckets ?? []).enumerated().sorted { lhs, rhs in
            let lhsRank = cadenceRank(lhs.element)
            let rhsRank = cadenceRank(rhs.element)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }
        return sortedBuckets.compactMap { indexedBucket in
            window(from: indexedBucket.element, group: group.displayName)
        }
    }

    private static func legacyWindows(_ buckets: [Bucket]) -> [UsageWindow] {
        buckets.compactMap { window(from: $0, group: nil) }
    }

    private static func window(from bucket: Bucket, group: String?) -> UsageWindow? {
        guard bucket.disabled != true else { return nil }
        let rawID = id(for: bucket, group: group)
        let reset = bucket.resetTime.flatMap(parseDate)
        let minutes = durationMinutes(for: bucket)
        let label = label(for: bucket, group: group)
        if let remaining = bucket.fraction, (0...1).contains(remaining) {
            return UsageWindow(
                id: "antigravity-\(rawID)",
                label: label,
                usedPercent: (1 - remaining) * 100,
                resetsAt: reset,
                durationMinutes: minutes
            )
        }
        guard let limit = bucket.limit, limit > 0,
              let used = bucket.used, used >= 0, used <= limit * 1.5
        else { return nil }
        return UsageWindow(
            id: "antigravity-\(rawID)",
            label: label,
            usedPercent: min(100, used / limit * 100),
            resetsAt: reset,
            durationMinutes: minutes
        )
    }

    private static func modelWindows(_ buckets: [Bucket], now: Date) -> [UsageWindow] {
        var geminiHourly: [Candidate] = []
        var geminiWeekly: [Candidate] = []
        var thirdPartyHourly: [Candidate] = []
        var thirdPartyWeekly: [Candidate] = []

        for bucket in buckets {
            guard let remaining = bucket.fraction, (0...1).contains(remaining) else { continue }
            let model = normalized(bucket.modelId ?? id(for: bucket, group: nil))
            guard !model.isEmpty, !model.starts(with: "chat_") else { continue }
            let resetDate = bucket.resetTime.flatMap(parseDate)
            let resetIsWeekly = resetDate.map { $0.timeIntervalSince(now) > 24 * 3600 } ?? false
            let isWeekly = cadenceRank(bucket) == 1 || resetIsWeekly
            let candidate = Candidate(remaining: remaining, resetDate: resetDate, isWeekly: isWeekly)
            if model.contains("gemini") {
                if isWeekly { geminiWeekly.append(candidate) } else { geminiHourly.append(candidate) }
            } else if model.contains("claude") || model.contains("gpt") || model.contains("openai") {
                if isWeekly { thirdPartyWeekly.append(candidate) } else { thirdPartyHourly.append(candidate) }
            }
        }

        var windows: [UsageWindow] = []
        if let window = aggregate(geminiHourly, id: "gemini-hourly",
                                  label: String(localized: "Gemini 5-hour limit", bundle: .language), weekly: false) {
            windows.append(window)
        }
        if let window = aggregate(geminiWeekly, id: "gemini-weekly",
                                  label: String(localized: "Gemini weekly limit", bundle: .language), weekly: true) {
            windows.append(window)
        }
        if let window = aggregate(thirdPartyHourly, id: "3p-hourly",
                                  label: String(localized: "Claude/GPT 5-hour limit", bundle: .language), weekly: false) {
            windows.append(window)
        }
        if let window = aggregate(thirdPartyWeekly, id: "3p-weekly",
                                  label: String(localized: "Claude/GPT weekly limit", bundle: .language), weekly: true) {
            windows.append(window)
        }
        return windows
    }

    private static func aggregate(_ candidates: [Candidate], id: String, label: String, weekly: Bool) -> UsageWindow? {
        guard let best = candidates.min(by: { $0.remaining < $1.remaining }) else { return nil }
        return UsageWindow(
            id: "antigravity-\(id)",
            label: label,
            usedPercent: (1 - best.remaining) * 100,
            resetsAt: best.resetDate,
            durationMinutes: weekly ? 10_080 : 300
        )
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func groupRank(_ value: String?) -> Int {
        let normalized = normalized(value ?? "")
        if normalized.contains("gemini") { return 0 }
        if normalized.contains("claude") || normalized.contains("gpt") { return 1 }
        return 2
    }

    private static func cadenceRank(_ bucket: Bucket) -> Int {
        if let value = cadenceValue(bucket.window), isWeeklyValue(value) { return 1 }
        if let value = cadenceValue(bucket.bucketId), isWeeklyValue(value) { return 1 }
        if let value = cadenceValue(bucket.displayName), isWeeklyValue(value) { return 1 }
        if let value = cadenceValue(bucket.window), isSessionValue(value) { return 0 }
        if let value = cadenceValue(bucket.bucketId), isSessionValue(value) { return 0 }
        if let value = cadenceValue(bucket.displayName), isSessionValue(value) { return 0 }
        return 2
    }

    private static func cadenceValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = normalized(raw)
        guard !value.isEmpty else { return nil }
        return value.hasSuffix(" limit") ? String(value.dropLast(" limit".count)) : value
    }

    private static func isWeeklyValue(_ value: String) -> Bool {
        value == "weekly" || value.hasSuffix("-weekly") || value.hasSuffix(" weekly") || value.contains("week")
    }

    private static func isSessionValue(_ value: String) -> Bool {
        value == "session" || value == "5h" || value == "5-hour" ||
            value == "five hour" || value == "five-hour" || value == "hourly" ||
            value.hasSuffix("-session") || value.hasSuffix("-5h") ||
            value.hasSuffix("-5-hour") || value.hasSuffix("-five-hour") ||
            value.hasSuffix("-hourly")
    }

    private static func durationMinutes(for bucket: Bucket) -> Int? {
        switch cadenceRank(bucket) {
        case 0: return 300
        case 1: return 10_080
        default: return nil
        }
    }

    private static func label(for bucket: Bucket, group: String?) -> String {
        let groupName = shortGroupName(group ?? "")
        switch cadenceRank(bucket) {
        case 0:
            return groupName.isEmpty
                ? String(localized: "5-hour limit", bundle: .language)
                : "\(groupName) \(String(localized: "5-hour limit", bundle: .language))"
        case 1:
            return groupName.isEmpty
                ? String(localized: "Weekly limit", bundle: .language)
                : "\(groupName) \(String(localized: "Weekly limit", bundle: .language))"
        default:
            var value = bucket.displayName ?? id(for: bucket, group: group)
            if value.hasSuffix(" Remaining") { value = String(value.dropLast(" Remaining".count)) }
            if value == "Five Hour Limit" { value = String(localized: "5-hour limit", bundle: .language) }
            return groupName.isEmpty ? value : "\(groupName) \(value)"
        }
    }

    private static func id(for bucket: Bucket, group: String?) -> String {
        [bucket.bucketId, bucket.modelId, bucket.name, group]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .first ?? "quota"
    }

    /// `GetUserStatus`: account email and plan tier.
    static func identity(fromUserStatus data: Data) -> Identity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any]
        else { return nil }
        let tier = (status["userTier"] as? [String: Any])?["name"] as? String
        let planInfo = (status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        let plan = tier ?? planInfo?["planName"] as? String ?? planInfo?["planDisplayName"] as? String
        return Identity(email: status["email"] as? String, plan: plan.map { "Antigravity \($0)" })
    }

    private static func shortGroupName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("gemini") { return "Gemini" }
        if lower.contains("claude") || lower.contains("gpt") { return "Claude/GPT" }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        if let seconds = Double(value) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}

enum AntigravityProviderError: LocalizedError, ProviderHealthDescribing {
    case notRunning(installed: Bool)
    case noListeningPorts
    case noReachableServer
    case transport(String)
    case rejected(Int)
    case unexpectedStatus(Int)
    case malformedResponse
    case invalidValue(String)
    case noQuotaBuckets

    var errorDescription: String? {
        switch self {
        case .notRunning(let installed):
            installed
                ? String(localized: "Antigravity is not running. Open Antigravity to read its quota.", bundle: .language)
                : String(localized: "Antigravity is not installed.", bundle: .language)
        case .noListeningPorts: String(localized: "Antigravity is starting up and not accepting requests yet.", bundle: .language)
        case .noReachableServer: String(localized: "Antigravity's local server did not answer.", bundle: .language)
        case .transport(let detail): String(localized: "Antigravity's local server could not be reached: \(detail)", bundle: .language)
        case .rejected(let status): String(localized: "Antigravity's local server rejected the request (\(status)). Restart Antigravity.", bundle: .language)
        case .unexpectedStatus(let status): String(localized: "Antigravity's local server returned an unexpected response (\(status)).", bundle: .language)
        case .malformedResponse: String(localized: "Antigravity returned an unsupported quota response.", bundle: .language)
        case .invalidValue(let bucket): String(localized: "Antigravity reported an out-of-range value for \(bucket).", bundle: .language)
        case .noQuotaBuckets: String(localized: "Antigravity reported no quota buckets.", bundle: .language)
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? String(localized: "Unknown Antigravity error", bundle: .language)
        switch self {
        case .notRunning(let installed): return installed ? .stale(message) : .unavailable(message)
        case .noListeningPorts, .noReachableServer, .transport: return .stale(message)
        default: return .unavailable(message)
        }
    }
}
