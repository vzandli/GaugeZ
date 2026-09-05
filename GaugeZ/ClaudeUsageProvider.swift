import AppKit
import CommonCrypto
import Foundation
import Security

/// Reads Claude usage from two sources, in this order:
///
/// 1. The Claude desktop app via Keychain (service `Claude Safe Storage`), decrypting its
///    token cache from `config.json` to query live usage and reset times. If Keychain access
///    is not granted, it gracefully falls back to the desktop usage log (`plan-usage-history.json`).
/// 2. The Claude Code CLI sign-in in the login Keychain (service `Claude Code-credentials`),
///    used to call the same OAuth usage endpoint Claude Code calls.
actor ClaudeUsageProvider: UsageProviding {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let keychainServicePrefix = "Claude Code"
    static let preferredKeychainService = "Claude Code-credentials"

    private let session: URLSession
    private let selectedSource: @Sendable () -> ClaudeSource
    private let retryPolicy = ProviderRetryPolicy(provider: .claude)

    init(selectedSource: @escaping @Sendable () -> ClaudeSource) {
        self.selectedSource = selectedSource
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        let source = selectedSource()
        switch source {
        case .claudeCode:
            return try await fetchViaClaudeCode()
        case .desktop:
            // Claude Desktop keeps its own usage log current, so a fresh log is the primary
            // reading; the rate-limited API is only asked when the log has gone stale.
            let local = try? ClaudeDesktopUsageReader.latestSnapshot()
            if let local, local.health == .live { return local }
            do {
                return try await fetchViaClaudeDesktop()
            } catch {
                if let local { return local }
                throw error
            }
        }
    }

    private func fetchViaClaudeCode() async throws -> UsageSnapshot {
        let credential = try ClaudeCredentialReader.load()
        return try await fetchViaCredential(credential)
    }

    private func fetchViaClaudeDesktop() async throws -> UsageSnapshot {
        let credential = try ClaudeDesktopCredentialReader.load()
        return try await fetchViaCredential(credential)
    }

    private func fetchViaCredential(_ credential: ClaudeCredential) async throws -> UsageSnapshot {
        if let expiresAt = credential.expiresAt, expiresAt.addingTimeInterval(60) < .now {
            throw ClaudeProviderError.tokenExpired
        }
        // Checked here, not in fetchSnapshot, so the desktop local-log fallback still runs during backoff.
        try retryPolicy.check()

        let usage = try await requestUsage(token: credential.accessToken)
        let identity = await resolveIdentity(token: credential.accessToken)

        let windows = try ClaudeUsageParser.windows(from: usage)
        guard !windows.isEmpty else { throw ClaudeProviderError.noUsageWindows }

        return UsageSnapshot(
            provider: .claude,
            accountID: identity?.email,
            planName: planName(credential: credential, identity: identity),
            windows: windows,
            observedAt: .now,
            source: credential.sourceDescription,
            health: .live
        )
    }

    // MARK: - Network

    private func requestUsage(token: String) async throws -> Data {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        applyHeaders(to: &request, token: token)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ClaudeProviderError.offline(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeProviderError.malformedResponse
        }

        switch http.statusCode {
        case 200:
            retryPolicy.succeeded()
            return data
        case 401:
            throw ClaudeProviderError.unauthorized
        case 403:
            throw ClaudeProviderError.forbidden
        case 429:
            throw retryPolicy.throttled(response: http)
        case 500...599:
            throw ClaudeProviderError.server(http.statusCode)
        default:
            throw ClaudeProviderError.unexpectedStatus(http.statusCode)
        }
    }

    /// Resolve identity from the credential used for this request; local CLI metadata may
    /// describe a different account from the selected desktop source. Memoized per token so
    /// the profile endpoint is hit once per credential, not once per refresh.
    private func resolveIdentity(token: String) async -> ClaudeIdentity? {
        if let cached = cachedIdentity, cached.token == token { return cached.identity }
        let identity = await requestIdentity(token: token)
        if let identity { cachedIdentity = (token, identity) }
        return identity
    }

    private var cachedIdentity: (token: String, identity: ClaudeIdentity)?

    private func requestIdentity(token: String) async -> ClaudeIdentity? {
        var request = URLRequest(url: Self.profileURL)
        applyHeaders(to: &request, token: token)
        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let account = object["account"] as? [String: Any]
        let organization = object["organization"] as? [String: Any]
        let identity = ClaudeIdentity(
            email: account?["email_address"] as? String,
            organizationName: organization?["name"] as? String,
            rateLimitTier: organization?["rate_limit_tier"] as? String
        )
        return identity
    }

    private func applyHeaders(to request: inout URLRequest, token: String) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GaugeZ/\(version)", forHTTPHeaderField: "User-Agent")
    }

    private func planName(credential: ClaudeCredential, identity: ClaudeIdentity?) -> String? {
        if let subscription = credential.subscriptionType, !subscription.isEmpty {
            return "Claude \(subscription.capitalized)"
        }
        return nil
    }
}

// MARK: - Credential access

struct ClaudeCredential {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let sourceDescription: String
}

struct ClaudeIdentity {
    let email: String?
    let organizationName: String?
    let rateLimitTier: String?
}

enum ClaudeCredentialReader {
    /// Locates the Claude Code sign-in. Keychain items take precedence over the file fallback
    /// that Claude Code writes on systems without a Keychain.
    static func load() throws -> ClaudeCredential {
        var sawPermissionProblem: OSStatus?

        for service in candidateKeychainServices() {
            switch readKeychainItem(service: service) {
            case .success(let data):
                return try decode(data, source: "via Claude Code (Keychain)")
            case .failure(.notFound):
                continue
            case .failure(.denied(let status)):
                sawPermissionProblem = status
            case .failure(.other(let status)):
                sawPermissionProblem = sawPermissionProblem ?? status
            }
        }

        if let fileData = readCredentialFile() {
            return try decode(fileData, source: "via Claude Code (credentials file)")
        }

        if let status = sawPermissionProblem {
            throw ClaudeProviderError.keychainDenied(status)
        }
        throw ClaudeProviderError.notSignedIn
    }

    private static func candidateKeychainServices() -> [String] {
        var services = [ClaudeUsageProvider.preferredKeychainService]

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                guard
                    let service = item[kSecAttrService as String] as? String,
                    service.hasPrefix(ClaudeUsageProvider.keychainServicePrefix),
                    !services.contains(service)
                else { continue }
                services.append(service)
            }
        }
        return services
    }

    private enum KeychainFailure: Error {
        case notFound
        case denied(OSStatus)
        case other(OSStatus)
    }

    private static func readKeychainItem(service: String) -> Result<Data, KeychainFailure> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else { return .failure(.notFound) }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.notFound)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecInteractionRequired:
            return .failure(.denied(status))
        default:
            return .failure(.other(status))
        }
    }

    private static func readCredentialFile() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
        return try? Data(contentsOf: url)
    }

    private static func decode(_ data: Data, source: String) throws -> ClaudeCredential {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = object["claudeAiOauth"] as? [String: Any]
        else { throw ClaudeProviderError.malformedCredential }

        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ClaudeProviderError.notSignedIn
        }

        var expiresAt: Date?
        if let millis = (oauth["expiresAt"] as? NSNumber)?.doubleValue, millis > 0 {
            expiresAt = Date(timeIntervalSince1970: millis / 1000)
        }

        return ClaudeCredential(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            sourceDescription: source
        )
    }
}

enum ClaudeDesktopCredentialReader {
    static let candidateServices = [
        "Claude Safe Storage",
        "Electron Safe Storage"
    ]

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/config.json")
    }

    /// Reads and decrypts the OAuth token from Claude Desktop's encrypted config.
    static func load() throws -> ClaudeCredential {
        var sawPermissionProblem: OSStatus?
        var passwordData: Data?

        for service in candidateServices {
            switch readKeychainPassword(service: service) {
            case .success(let data):
                passwordData = data
            case .failure(.notFound):
                continue
            case .failure(.denied(let status)):
                sawPermissionProblem = status
            case .failure(.other(let status)):
                sawPermissionProblem = sawPermissionProblem ?? status
            }
            if passwordData != nil { break }
        }

        guard let passwordData else {
            if let status = sawPermissionProblem {
                throw ClaudeProviderError.keychainDenied(status)
            }
            throw ClaudeProviderError.notSignedIn
        }

        guard let configData = try? Data(contentsOf: configURL),
              let config = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any]
        else {
            throw ClaudeProviderError.noDesktopLog
        }

        guard let tokenCacheB64 = (config["oauth:tokenCacheV2"] as? String) ?? (config["oauth:tokenCache"] as? String),
              let encryptedData = Data(base64Encoded: tokenCacheB64)
        else {
            throw ClaudeProviderError.notSignedIn
        }

        let decryptedData = try decrypt(encryptedData: encryptedData, password: passwordData)
        guard let tokenCache = (try? JSONSerialization.jsonObject(with: decryptedData)) as? [String: [String: Any]] else {
            throw ClaudeProviderError.malformedCredential
        }

        // Find the best valid token from the token cache.
        var bestToken: String?
        var bestExpiresAt: Date?
        var bestSubscription: String?
        var latestExpiry: Double = 0

        for (_, entry) in tokenCache {
            guard let token = entry["token"] as? String, !token.isEmpty else { continue }
            let expiresMillis = (entry["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            let subscription = entry["subscriptionType"] as? String

            if bestToken == nil || expiresMillis > latestExpiry {
                bestToken = token
                latestExpiry = expiresMillis
                bestExpiresAt = expiresMillis > 0 ? Date(timeIntervalSince1970: expiresMillis / 1000) : nil
                bestSubscription = subscription
            }
        }

        guard let token = bestToken else {
            throw ClaudeProviderError.notSignedIn
        }

        return ClaudeCredential(
            accessToken: token,
            expiresAt: bestExpiresAt,
            subscriptionType: bestSubscription,
            sourceDescription: "via Claude Desktop (Keychain)"
        )
    }

    private static func decrypt(encryptedData: Data, password: Data) throws -> Data {
        guard encryptedData.count > 3 else {
            throw ClaudeProviderError.malformedCredential
        }

        // Chromium OSCrypt v10 check: starts with "v10" (ASCII 0x76, 0x31, 0x30)
        let header = encryptedData.prefix(3)
        guard header == Data([0x76, 0x31, 0x30]) else {
            throw ClaudeProviderError.malformedCredential
        }
        let ciphertext = encryptedData.dropFirst(3)

        // Chromium macOS key derivation: PBKDF2 with HMAC-SHA1, 1003 rounds, 16-byte key, salt "saltysalt"
        let salt = "saltysalt".data(using: .utf8)!
        var key = Data(count: 16)
        let keyStatus = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        16
                    )
                }
            }
        }
        guard keyStatus == kCCSuccess else {
            throw ClaudeProviderError.malformedCredential
        }

        // Chromium macOS IV is 16 space characters (0x20)
        let iv = Data(repeating: 0x20, count: 16)

        var decrypted = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var numBytesDecrypted: size_t = 0

        let cryptStatus = decrypted.withUnsafeMutableBytes { decBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, 16,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress, ciphertext.count,
                            decBytes.baseAddress, decBytes.count,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard cryptStatus == kCCSuccess else {
            throw ClaudeProviderError.malformedCredential
        }
        decrypted.count = numBytesDecrypted
        return decrypted
    }

    private enum KeychainFailure: Error {
        case notFound
        case denied(OSStatus)
        case other(OSStatus)
    }

    private static func readKeychainPassword(service: String) -> Result<Data, KeychainFailure> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else { return .failure(.notFound) }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.notFound)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecInteractionRequired:
            return .failure(.denied(status))
        default:
            return .failure(.other(status))
        }
    }
}

// MARK: - Response parsing

enum ClaudeUsageParser {
    /// Every top-level object carrying a numeric `utilization` becomes a window, so windows that
    /// Claude adds later (model-specific weekly limits, for example) still show up with a
    /// readable label instead of being dropped.
    static func windows(from data: Data) throws -> [UsageWindow] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeProviderError.malformedResponse
        }

        var windows: [(order: Int, window: UsageWindow)] = []
        for (key, value) in object {
            guard let bucket = value as? [String: Any] else { continue }

            if key == "extra_usage" {
                guard (bucket["is_enabled"] as? Bool) == true else { continue }
            }
            guard let utilization = (bucket["utilization"] as? NSNumber)?.doubleValue else { continue }
            guard utilization.isFinite, utilization >= 0, utilization <= 100.5 else {
                throw ClaudeProviderError.invalidUtilization(key)
            }

            let resetsAt = (bucket["resets_at"] as? String).flatMap(parseDate)
            let descriptor = describe(key: key)
            windows.append((
                descriptor.order,
                UsageWindow(
                    id: key,
                    label: descriptor.label,
                    usedPercent: Int(utilization.rounded()),
                    resetsAt: resetsAt,
                    durationMinutes: descriptor.durationMinutes
                )
            ))
        }

        return windows
            .sorted { lhs, rhs in
                lhs.order == rhs.order ? lhs.window.id < rhs.window.id : lhs.order < rhs.order
            }
            .map(\.window)
    }

    private static func describe(key: String) -> (label: String, order: Int, durationMinutes: Int?) {
        switch key {
        case "five_hour": return ("5-hour limit", 0, 300)
        case "seven_day": return ("Weekly limit", 1, 10_080)
        case "seven_day_opus": return ("Weekly Opus limit", 2, 10_080)
        case "seven_day_sonnet": return ("Weekly Sonnet limit", 3, 10_080)
        case "seven_day_oauth_apps": return ("Weekly connected apps", 4, 10_080)
        case "extra_usage": return ("Extra usage", 9, nil)
        default:
            let readable = key
                .replacingOccurrences(of: "seven_day_", with: "weekly ")
                .replacingOccurrences(of: "_", with: " ")
            return (readable.prefix(1).uppercased() + readable.dropFirst() + " limit", 5, nil)
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

// MARK: - Errors

enum ClaudeProviderError: LocalizedError, ProviderHealthDescribing {
    case noDesktopLog
    case desktopLogMalformed
    case notSignedIn
    case keychainDenied(OSStatus)
    case malformedCredential
    case tokenExpired
    case unauthorized
    case forbidden
    case rateLimited(until: Date)
    case offline(String)
    case server(Int)
    case unexpectedStatus(Int)
    case malformedResponse
    case invalidUtilization(String)
    case noUsageWindows

    var errorDescription: String? {
        switch self {
        case .noDesktopLog:
            "Claude Desktop has not recorded usage yet. Open Claude and sign in, or switch the Claude source to the Claude Code CLI."
        case .desktopLogMalformed:
            "Claude's usage log has an unsupported format."
        case .notSignedIn:
            "No Claude Code CLI sign-in was found in Keychain. Run `claude` and sign in, or switch the Claude source to the desktop app."
        case .keychainDenied:
            "GaugeZ needs permission to read the Claude Code sign-in from your Keychain."
        case .malformedCredential:
            "The Claude Code sign-in has an unsupported format."
        case .tokenExpired:
            "The Claude Code sign-in has expired. Open Claude Code once so it can refresh, then retry."
        case .unauthorized:
            "Claude rejected the Claude Code sign-in. Sign in to Claude Code again."
        case .forbidden:
            "This Claude account cannot read usage through Claude Code."
        case .rateLimited(let until):
            "Claude asked GaugeZ to wait until \(until.formatted(date: .omitted, time: .shortened))."
        case .offline(let detail):
            "Claude could not be reached: \(detail)"
        case .server(let status):
            "Claude returned a server error (\(status))."
        case .unexpectedStatus(let status):
            "Claude returned an unexpected response (\(status))."
        case .malformedResponse:
            "Claude returned an unsupported usage response."
        case .invalidUtilization(let key):
            "Claude reported an out-of-range value for \(key)."
        case .noUsageWindows:
            "Claude reported no usage windows."
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? "Unknown Claude error"
        switch self {
        case .noDesktopLog, .notSignedIn, .tokenExpired, .unauthorized:
            return .signedOut(message)
        case .keychainDenied:
            return .permissionRequired(message)
        case .rateLimited, .offline, .server:
            return .stale(message)
        case .forbidden, .malformedCredential, .unexpectedStatus, .malformedResponse,
             .invalidUtilization, .noUsageWindows, .desktopLogMalformed:
            return .unavailable(message)
        }
    }
}

// MARK: - Claude desktop app usage log

/// Reads the usage samples the Claude desktop app keeps for its own plan-usage display.
/// Each sample records a timestamp, the organization, and used percentages for the
/// five-hour window (`fh`), the seven-day window (`sd`), and extra usage (`xu`).
enum ClaudeDesktopUsageReader {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    /// The desktop app samples every few minutes while it runs; anything older than this is
    /// shown as stale rather than live.
    static let freshnessInterval: TimeInterval = 20 * 60

    struct Sample: Equatable {
        let time: Date
        let organization: String?
        let utilization: [String: Double]
    }

    static var historyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// Returns nil when the desktop app has never written a usage log.
    static func latestSnapshot(now: Date = .now) throws -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: historyURL) else { return nil }
        guard let sample = try latestSample(in: data) else { return nil }
        return try snapshot(from: sample, now: now)
    }

    static func latestSample(in data: Data) throws -> Sample? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let samples = object["samples"] as? [[String: Any]]
        else { throw ClaudeProviderError.desktopLogMalformed }

        var latest: Sample?
        for raw in samples {
            guard
                let millis = (raw["t"] as? NSNumber)?.doubleValue,
                millis > 0,
                let usage = raw["u"] as? [String: Any]
            else { continue }
            var utilization: [String: Double] = [:]
            for (key, value) in usage {
                if let number = (value as? NSNumber)?.doubleValue {
                    utilization[key] = number
                }
            }
            let sample = Sample(
                time: Date(timeIntervalSince1970: millis / 1000),
                organization: raw["org"] as? String,
                utilization: utilization
            )
            if latest == nil || sample.time > latest!.time {
                latest = sample
            }
        }
        return latest
    }

    static func snapshot(from sample: Sample, now: Date = .now) throws -> UsageSnapshot {
        var windows: [UsageWindow] = []
        for (key, label, duration) in descriptors {
            guard let value = sample.utilization[key] else { continue }
            guard value.isFinite, value >= 0, value <= 100.5 else {
                throw ClaudeProviderError.invalidUtilization(key)
            }
            // Extra usage is only worth a row once it has been touched; the desktop app logs
            // zero for accounts that have it switched off.
            if key == "xu", value == 0 { continue }
            windows.append(UsageWindow(
                id: "desktop-\(key)",
                label: label,
                usedPercent: Int(value.rounded()),
                resetsAt: nil,
                durationMinutes: duration
            ))
        }
        guard !windows.isEmpty else { throw ClaudeProviderError.noUsageWindows }

        let age = now.timeIntervalSince(sample.time)
        let health: ProviderHealth
        if age <= freshnessInterval {
            health = .live
        } else {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            let when = relative.localizedString(for: sample.time, relativeTo: now)
            let hint = isDesktopAppRunning()
                ? "Claude has not recorded newer usage yet."
                : "Open Claude so it records fresh usage."
            health = .stale("Claude last recorded usage \(when). \(hint)")
        }

        return UsageSnapshot(
            provider: .claude,
            accountID: nil,
            planName: nil,
            windows: windows,
            observedAt: sample.time,
            source: "Claude desktop usage log",
            health: health
        )
    }

    private static let descriptors: [(String, String, Int?)] = [
        ("fh", "5-hour limit", 300),
        ("sd", "Weekly limit", 10_080),
        ("xu", "Extra usage", nil)
    ]

    private static func isDesktopAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
