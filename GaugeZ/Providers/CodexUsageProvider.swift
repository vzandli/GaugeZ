import Foundation

/// Reads Codex rate limits from the app-server bundled with Codex, ChatGPT, or an installed
/// `codex` CLI. When no executable can be found but the CLI has signed in to ChatGPT
/// (`~/.codex/auth.json`), the same figures are read from the usage endpoint Codex itself calls,
/// with the token Codex owns and refreshes. GaugeZ never writes that file or refreshes the token.
actor CodexUsageProvider: UsageProviding {
    private let session: URLSession
    private let retryPolicy: ProviderRetryPolicy
    private let profile: CodexProfile
    private let locateExecutable: @Sendable () -> URL?
    private let loadCredential: @Sendable () throws -> CodexWebCredential?

    init(profile: CodexProfile = CodexProfile(), session: URLSession? = nil, retryPolicy: ProviderRetryPolicy? = nil,
         locateExecutable: @escaping @Sendable () -> URL? = { CodexInstallation.locateExecutable() },
         loadCredential: (@Sendable () throws -> CodexWebCredential?)? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.profile = profile
        self.session = session ?? URLSession(configuration: configuration)
        self.retryPolicy = retryPolicy ?? ProviderRetryPolicy(provider: profile.provider)
        self.locateExecutable = locateExecutable
        self.loadCredential = loadCredential ?? { try CodexWebCredential.load(url: profile.authURL) }
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        // Extra homes are their own ChatGPT sign-in. The bundled app-server talks to whichever
        // account the default Codex install is using, so it must not answer for a named profile.
        if profile.slug == nil, let executable = locateExecutable() {
            let snapshot = try await appServerSnapshot(executable: executable)
            retryPolicy.succeeded()
            let credential = try? loadCredential()
            return await attachingResetCredits(snapshot, credential: credential)
        }
        let snapshot = try await webSnapshot()
        retryPolicy.succeeded()
        return snapshot
    }

    private func appServerSnapshot(executable: URL) async throws -> UsageSnapshot {
        let probe = CodexAppServerProbe(executable: executable)
        do {
            return try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try probe.run()
                }.value
            } onCancel: {
                probe.cancel()
            }
        } catch CodexProviderError.server(let message) where CodexProviderError.looksThrottled(message) {
            // The app-server relays ChatGPT's 429 as an error message with no Retry-After, so the
            // wait is the policy's own floor, persisted like every other provider's.
            throw retryPolicy.throttled(retryAfter: nil)
        }
    }

    private func webSnapshot() async throws -> UsageSnapshot {
        let credential: CodexWebCredential
        do {
            guard let loaded = try loadCredential() else {
                throw profile.slug == nil
                    ? CodexProviderError.notInstalled
                    : CodexProviderError.profileNotSignedIn(profile.signInGuidance)
            }
            credential = loaded
        } catch CodexProviderError.notSignedIn where profile.slug != nil {
            throw CodexProviderError.profileNotSignedIn(profile.signInGuidance)
        }
        if let expiresAt = credential.expiresAt, expiresAt < .now { throw CodexProviderError.sessionExpired }

        var request = URLRequest(url: CodexWebUsage.endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("GaugeZ/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CodexProviderError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CodexProviderError.malformedResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw CodexProviderError.unauthorized
        case 429: throw retryPolicy.throttled(response: http)
        case 500...599: throw CodexProviderError.server("HTTP \(http.statusCode)")
        default: throw CodexProviderError.unexpectedStatus(http.statusCode)
        }

        let windows = try CodexWebUsage.windows(from: data)
        let snapshot = UsageSnapshot(
            provider: profile.provider,
            accountID: credential.email,
            planName: credential.planType.map { "ChatGPT \($0.capitalized)" },
            windows: windows,
            observedAt: .now,
            source: "ChatGPT usage endpoint (Codex CLI sign-in)",
            health: .live
        )
        return await attachingResetCredits(snapshot, credential: credential)
    }

    private func attachingResetCredits(_ snapshot: UsageSnapshot, credential: CodexWebCredential?) async -> UsageSnapshot {
        guard let credential else { return snapshot }
        let credits = await Self.fetchResetCredits(session: session, credential: credential)
        return snapshot.withResetCredits(credits)
    }

    private static func fetchResetCredits(session: URLSession, credential: CodexWebCredential) async -> CodexResetCredits? {
        var request = URLRequest(url: CodexWebUsage.resetCreditsEndpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("GaugeZ/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return nil }
            return try CodexWebUsage.resetCredits(from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Executable discovery

enum CodexInstallation {
    /// The app bundles first, then a `codex` on the user's PATH and in the places package managers
    /// put it. A GUI app inherits a minimal PATH, so the usual install directories are listed
    /// explicitly rather than trusted to be there.
    static let applicationBundles = [
        URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    ]

    static func locateExecutable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 applicationBundles: [URL] = applicationBundles) -> URL? {
        var candidates = applicationBundles
        candidates += searchDirectories(home: home, environment: environment)
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func searchDirectories(home: URL, environment: [String: String]) -> [String] {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin"]
        directories += [".npm-global/bin", ".local/bin", ".bun/bin", ".volta/bin", ".yarn/bin", ".cargo/bin"]
            .map { home.appendingPathComponent($0).path }
        // nvm keeps one bin directory per Node version; newest first.
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            directories += versions.sorted(by: >).map { nvm.appendingPathComponent("\($0)/bin").path }
        }
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// An npm-installed `codex` is a launcher that needs `node` on the PATH of the process running
    /// it, and a GUI app's PATH does not include where package managers put one.
    static func environment(for executable: URL, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let directories = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
            + (base["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = directories.filter { seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }
}

// MARK: - CLI sign-in (HTTP fallback)

/// Borrowed from `~/.codex/auth.json`, the CLI's own ChatGPT sign-in. Only read when no app-server
/// executable exists; the token is used for one request and never persisted or logged.
struct CodexWebCredential: Sendable {
    let accessToken: String
    let accountID: String
    let expiresAt: Date?
    let email: String?
    let planType: String?

    static func authURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".codex/auth.json")
    }

    /// Nil when the CLI has never signed in (no file). A file without ChatGPT tokens, which is what
    /// an API-key sign-in writes, has no usage limits to read and is reported as signed out.
    static func load(url: URL = authURL()) throws -> CodexWebCredential? {
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) < 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> CodexWebCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexProviderError.malformedCredential
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let token = headerSafe(tokens["access_token"]),
              let account = headerSafe(tokens["account_id"]) else {
            throw CodexProviderError.notSignedIn
        }
        var expiresAt: Date?
        if let exp = (jwtClaims(token)?["exp"] as? NSNumber)?.doubleValue, exp.isFinite, exp > 0 {
            expiresAt = Date(timeIntervalSince1970: exp)
        }
        let identity = (tokens["id_token"] as? String).flatMap(jwtClaims)
        let auth = identity?["https://api.openai.com/auth"] as? [String: Any]
        return CodexWebCredential(
            accessToken: token,
            accountID: account,
            expiresAt: expiresAt,
            email: identity?["email"] as? String,
            planType: auth?["chatgpt_plan_type"] as? String
        )
    }

    /// Claims supply identity labels and a local expiry hint only; the server validates the token.
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func headerSafe(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.rangeOfCharacter(from: .newlines) == nil, text.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return text
    }
}

/// `GET https://chatgpt.com/backend-api/wham/usage`: the account's main windows only.
/// `additional_rate_limits` and `code_review_rate_limit` meter something else and are left out.
enum CodexWebUsage {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    static func windows(from data: Data, now: Date = .now) throws -> [UsageWindow] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexProviderError.malformedResponse
        }
        guard let limit = object["rate_limit"] as? [String: Any] else { throw CodexProviderError.noUsageWindows }
        var windows: [UsageWindow] = []
        for (id, fallback) in [("primary", String(localized: "Current limit", bundle: .language)), ("secondary", String(localized: "Weekly limit", bundle: .language))] {
            guard let window = limit["\(id)_window"] as? [String: Any] else { continue }
            guard let percent = (window["used_percent"] as? NSNumber)?.doubleValue, percent.isFinite else {
                throw CodexProviderError.malformedResponse
            }
            let seconds = (window["limit_window_seconds"] as? NSNumber)?.doubleValue
            let minutes = seconds.flatMap { $0.isFinite && $0 > 0 ? Int(($0 / 60).rounded()) : nil }
            var resetsAt: Date?
            if let epoch = (window["reset_at"] as? NSNumber)?.doubleValue, epoch.isFinite, epoch > 0 {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let after = (window["reset_after_seconds"] as? NSNumber)?.doubleValue, after.isFinite, after >= 0 {
                resetsAt = now.addingTimeInterval(after)
            }
            windows.append(UsageWindow(
                id: id,
                label: CodexWindowLabel.label(minutes: minutes, fallback: fallback),
                usedPercent: max(0, min(100, percent)),
                resetsAt: resetsAt,
                durationMinutes: minutes
            ))
        }
        guard !windows.isEmpty else { throw CodexProviderError.noUsageWindows }
        return windows
    }

    /// `available_count` is trusted even when the `credits` array is truncated. An unfamiliar
    /// JSON body yields an empty list rather than failing the usage fetch.
    static func resetCredits(from data: Data) throws -> CodexResetCredits {
        let response: ResetCreditsResponse
        do {
            response = try JSONDecoder().decode(ResetCreditsResponse.self, from: data)
        } catch {
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return CodexResetCredits(availableCount: 0, credits: [])
            }
            throw CodexProviderError.malformedResponse
        }
        let credits = response.credits.map {
            CodexResetCredits.Credit(id: $0.id, status: $0.status, expiresAt: $0.expiresAt)
        }
        let availableCount = response.availableCount
            ?? credits.filter { $0.status == "available" }.count
        return CodexResetCredits(availableCount: availableCount, credits: credits)
    }

    private struct ResetCreditsResponse: Decodable {
        let credits: [ResetCredit]
        let availableCount: Int?

        private enum CodingKeys: String, CodingKey {
            case credits
            case available_count
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            availableCount = try? container.decode(Int.self, forKey: .available_count)
            let items = (try? container.decode([FailableResetCredit].self, forKey: .credits)) ?? []
            credits = items.compactMap(\.value)
        }
    }

    private struct FailableResetCredit: Decodable {
        let value: ResetCredit?
        init(from decoder: Decoder) throws {
            value = try? ResetCredit(from: decoder)
        }
    }

    private struct ResetCredit: Decodable {
        let id: String
        let status: String
        let expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id, status, expires_at
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
            if let text = try? container.decode(String.self, forKey: .expires_at) {
                expiresAt = parseISO8601(text)
            } else {
                expiresAt = nil
            }
        }
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// Labels derive from the length Codex actually sent: a free plan reports a 30-day primary
/// window, not the 5-hour one a paid plan does, and an unrecognised length must not drop it.
enum CodexWindowLabel {
    static func label(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        switch minutes {
        case 300: return String(localized: "5-hour limit", bundle: .language)
        case 10_080: return String(localized: "Weekly limit", bundle: .language)
        case let value where value % 1_440 == 0: return String(localized: "\(value / 1_440)-day limit", bundle: .language)
        case let value where value % 60 == 0: return String(localized: "\(value / 60)-hour limit", bundle: .language)
        default: return String(localized: "\(minutes)-minute limit", bundle: .language)
        }
    }
}

// MARK: - App-server probe

private final class CodexAppServerProbe: @unchecked Sendable {
    private let executable: URL
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)

    private var buffer = Data()
    private var completed = false
    private var result: Result<UsageSnapshot, Error>?
    private var stderr = Data()

    init(executable: URL) {
        self.executable = executable
    }

    func cancel() { finish(.failure(CancellationError())) }

    func run() throws -> UsageSnapshot {
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.environment = CodexInstallation.environment(for: executable)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveError(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.processTerminated(status: process.terminationStatus)
        }

        do {
            try process.run()
            try send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "gaugez",
                        "title": "GaugeZ",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ])
        } catch {
            cleanup()
            throw error
        }

        let waitResult = completion.wait(timeout: .now() + 12)
        if waitResult == .timedOut {
            finish(.failure(CodexProviderError.timedOut))
        }

        cleanup()
        return try (result ?? .failure(CodexProviderError.noResponse)).get()
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[..<newline])
            buffer.removeSubrange(...newline)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            handleLine(line)
        }
    }

    private func handleLine(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = (object["id"] as? NSNumber)?.intValue
        else { return }

        if id == 1 {
            do {
                try send(["method": "initialized"])
                try send([
                    "id": 2,
                    "method": "account/rateLimits/read",
                    "params": [:]
                ])
            } catch {
                finish(.failure(error))
            }
            return
        }

        guard id == 2 else { return }
        do {
            if let errorObject = object["error"] as? [String: Any] {
                let message = errorObject["message"] as? String ?? "Codex returned an unknown error"
                throw CodexProviderError.server(message)
            }
            let envelope = try JSONDecoder().decode(RateLimitEnvelope.self, from: data)
            guard let response = envelope.result else {
                throw CodexProviderError.malformedResponse
            }
            finish(.success(try makeSnapshot(from: response)))
        } catch {
            finish(.failure(error))
        }
    }

    private func makeSnapshot(from response: RateLimitResponse) throws -> UsageSnapshot {
        let buckets: [(String, RateLimitSnapshot)]
        if let byID = response.rateLimitsByLimitId, !byID.isEmpty {
            buckets = byID.sorted(by: { $0.key < $1.key })
        } else if let legacy = response.rateLimits {
            buckets = [(legacy.limitId ?? "codex", legacy)]
        } else {
            throw CodexProviderError.noUsageWindows
        }

        var windows: [UsageWindow] = []
        var planName: String?
        for (bucketID, bucket) in buckets {
            planName = planName ?? bucket.planType
            if let primary = bucket.primary {
                windows.append(try primary.normalized(id: "\(bucketID)-primary", fallbackLabel: String(localized: "Current limit", bundle: .language)))
            }
            if let secondary = bucket.secondary {
                windows.append(try secondary.normalized(id: "\(bucketID)-secondary", fallbackLabel: String(localized: "Weekly limit", bundle: .language)))
            }
        }

        guard !windows.isEmpty else { throw CodexProviderError.noUsageWindows }
        return UsageSnapshot(
            provider: .codex,
            accountID: response.accountId,
            planName: planName.map { "ChatGPT \($0.capitalized)" },
            windows: windows,
            observedAt: .now,
            source: "Codex app-server",
            health: .live
        )
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var framed = data
        framed.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: framed)
    }

    private func receiveError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if stderr.count < 8192 { stderr.append(data.prefix(8192 - stderr.count)) }
        lock.unlock()
    }

    private func processTerminated(status: Int32) {
        guard status != 0 else { return }
        lock.lock()
        let message = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        finish(.failure(CodexProviderError.server(message?.isEmpty == false ? message! : "App server exited with status \(status)")))
    }

    private func finish(_ newResult: Result<UsageSnapshot, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        result = newResult
        lock.unlock()
        completion.signal()
    }

    private func cleanup() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
        }
        try? inputPipe.fileHandleForWriting.close()
    }
}

private struct RateLimitEnvelope: Decodable {
    let result: RateLimitResponse?
}

private struct RateLimitResponse: Decodable {
    let accountId: String?
    let rateLimits: RateLimitSnapshot?
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

private struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let resetsAt: Int64?
    let windowDurationMins: Int?

    /// `fallbackLabel` names the window when the server omits its duration; out-of-range
    /// percentages are clamped rather than rejected so one odd bucket cannot fail the snapshot.
    func normalized(id: String, fallbackLabel: String) throws -> UsageWindow {
        guard windowDurationMins.map({ $0 > 0 }) ?? true else {
            throw CodexProviderError.malformedResponse
        }
        return UsageWindow(
            id: id,
            label: CodexWindowLabel.label(minutes: windowDurationMins, fallback: fallbackLabel),
            usedPercent: max(0, min(100, usedPercent)),
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            durationMinutes: windowDurationMins
        )
    }
}

// MARK: - Errors

enum CodexProviderError: LocalizedError, ProviderHealthDescribing {
    case notInstalled
    case notSignedIn
    case profileNotSignedIn(String)
    case malformedCredential
    case sessionExpired
    case unauthorized
    case offline(String)
    case unexpectedStatus(Int)
    case timedOut
    case noResponse
    case malformedResponse
    case noUsageWindows
    case server(String)

    /// The app-server relays ChatGPT's throttling as text; these are the forms seen.
    static func looksThrottled(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("429") || lowered.contains("rate limit") || lowered.contains("too many requests")
    }

    private static func looksUnauthorized(_ message: String) -> Bool {
        message.contains("401") || message.contains("token") || message.contains("auth")
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return String(localized: "Codex is not installed. Install the Codex app, ChatGPT, or the codex CLI and sign in.", bundle: .language)
        case .notSignedIn:
            return String(localized: "The Codex CLI is not signed in to ChatGPT. Run `codex login`, or install the Codex app.", bundle: .language)
        case .profileNotSignedIn(let guidance):
            return guidance
        case .malformedCredential:
            return String(localized: "The Codex CLI sign-in has an unsupported format.", bundle: .language)
        case .sessionExpired:
            return String(localized: "The Codex CLI sign-in has expired. Run `codex` once so it refreshes, then retry.", bundle: .language)
        case .unauthorized:
            return String(localized: "ChatGPT rejected the Codex sign-in. Sign in to Codex again.", bundle: .language)
        case .offline(let detail):
            return String(localized: "ChatGPT could not be reached: \(detail)", bundle: .language)
        case .unexpectedStatus(let status):
            return String(localized: "ChatGPT returned an unexpected response (\(status)).", bundle: .language)
        case .timedOut:
            return String(localized: "Codex did not answer within 12 seconds.", bundle: .language)
        case .noResponse:
            return String(localized: "Codex returned no response.", bundle: .language)
        case .malformedResponse:
            return String(localized: "Codex returned an unsupported response.", bundle: .language)
        case .noUsageWindows:
            return String(localized: "Codex reported no usage windows.", bundle: .language)
        case .server(let message):
            if message.contains("404") || message.contains("wham/usage") {
                return String(localized: "ChatGPT rate limits are temporarily unavailable.", bundle: .language)
            } else if Self.looksUnauthorized(message) {
                return String(localized: "ChatGPT session expired. Sign in inside ChatGPT to refresh.", bundle: .language)
            }
            return String(localized: "Codex app-server could not provide usage. Open Codex and retry.", bundle: .language)
        }
    }

    var providerHealth: ProviderHealth {
        let text = errorDescription ?? String(localized: "Codex error", bundle: .language)
        switch self {
        case .server(let message) where Self.looksUnauthorized(message):
            return .signedOut(text)
        case .notSignedIn, .profileNotSignedIn, .unauthorized:
            return .signedOut(text)
        case .server, .timedOut, .noResponse, .sessionExpired, .offline:
            return .stale(text)
        default:
            return .unavailable(text)
        }
    }
}
