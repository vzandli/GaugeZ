import Foundation

/// Reads Antigravity model quotas from the language server that a running Antigravity app or
/// Antigravity IDE hosts on 127.0.0.1.
///
/// Nothing leaves the machine: GaugeZ finds the local server process, reads the CSRF token it
/// was launched with, and asks it for the same quota summary the IDE's own usage panel shows.
/// Antigravity's stored Google login is never read or replayed. When Antigravity is not running
/// the provider reports that honestly and the store keeps the last values marked stale.
actor AntigravityUsageProvider: UsageProviding {
    static let bundleIdentifiers = ["com.google.antigravity", "com.google.antigravity-ide"]
    private static let quotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let userStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"

    private let delegate = LocalhostTrustDelegate()
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
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

    /// `RetrieveUserQuotaSummary`: groups of models, each with session and weekly buckets.
    static func windows(fromQuotaSummary data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityProviderError.malformedResponse
        }
        let payload = (root["response"] as? [String: Any]) ?? (root["summary"] as? [String: Any]) ?? root
        guard let groups = payload["groups"] as? [[String: Any]] else {
            throw AntigravityProviderError.malformedResponse
        }

        var windows: [UsageWindow] = []
        for group in groups {
            let groupName = shortGroupName((group["displayName"] as? String) ?? "")
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let bucketID = bucket["bucketId"] as? String, !bucketID.isEmpty else { continue }
                if (bucket["disabled"] as? Bool) == true { continue }
                guard let fraction = remainingFraction(in: bucket) else { continue }
                guard fraction.isFinite, fraction >= -0.005, fraction <= 1.005 else {
                    throw AntigravityProviderError.invalidValue(bucketID)
                }

                let cadence = cadence(bucketID: bucketID, displayName: bucket["displayName"] as? String ?? "")
                windows.append(UsageWindow(
                    id: "antigravity-\(bucketID)",
                    label: "\(groupName) \(cadence.label)".trimmingCharacters(in: .whitespaces),
                    usedPercent: Int(((1 - min(1, max(0, fraction))) * 100).rounded()),
                    resetsAt: (bucket["resetTime"] as? String).flatMap(parseDate),
                    durationMinutes: cadence.minutes
                ))
            }
        }
        guard !windows.isEmpty else { throw AntigravityProviderError.noQuotaBuckets }
        return windows.sorted { lhs, rhs in
            (lhs.durationMinutes ?? .max, lhs.label) < (rhs.durationMinutes ?? .max, rhs.label)
        }
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

    private static func remainingFraction(in bucket: [String: Any]) -> Double? {
        if let direct = (bucket["remainingFraction"] as? NSNumber)?.doubleValue { return direct }
        guard let remaining = bucket["remaining"] as? [String: Any] else { return nil }
        if let value = (remaining["remainingFraction"] as? NSNumber)?.doubleValue { return value }
        if remaining["case"] as? String == "remainingFraction" {
            return (remaining["value"] as? NSNumber)?.doubleValue
        }
        return nil
    }

    private static func shortGroupName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("gemini") { return "Gemini" }
        if lower.contains("claude") || lower.contains("gpt") { return "Claude/GPT" }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private static func cadence(bucketID: String, displayName: String) -> (label: String, minutes: Int?) {
        let text = (bucketID + " " + displayName).lowercased().replacingOccurrences(of: "_", with: "-")
        if ["5h", "5-hour", "five hour", "five-hour", "session"].contains(where: text.contains) {
            return ("5-hour limit", 300)
        }
        if text.contains("weekly") || text.contains("week") {
            return ("weekly limit", 10_080)
        }
        return (displayName.isEmpty ? bucketID : displayName, nil)
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
                ? "Antigravity is not running. Open Antigravity to read its quota."
                : "Antigravity is not installed."
        case .noListeningPorts: "Antigravity is starting up and not accepting requests yet."
        case .noReachableServer: "Antigravity's local server did not answer."
        case .transport(let detail): "Antigravity's local server could not be reached: \(detail)"
        case .rejected(let status): "Antigravity's local server rejected the request (\(status)). Restart Antigravity."
        case .unexpectedStatus(let status): "Antigravity's local server returned an unexpected response (\(status))."
        case .malformedResponse: "Antigravity returned an unsupported quota response."
        case .invalidValue(let bucket): "Antigravity reported an out-of-range value for \(bucket)."
        case .noQuotaBuckets: "Antigravity reported no quota buckets."
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? "Unknown Antigravity error"
        switch self {
        case .notRunning(let installed): return installed ? .stale(message) : .unavailable(message)
        case .noListeningPorts, .noReachableServer, .transport: return .stale(message)
        default: return .unavailable(message)
        }
    }
}
