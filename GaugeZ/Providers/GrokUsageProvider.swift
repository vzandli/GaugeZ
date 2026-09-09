import Foundation
import CoreFoundation
import AppKit
import SQLite3

/// Protocol verified against xai-org/grok-build, revision 72a61251fcffb464bcc687aeb5a998e5a98ec0c9.
/// Usage reads never execute the CLI, refresh tokens, or write credentials; the only launch is the
/// user's explicit Open Grok Build action, which starts the installed CLI in Terminal.
actor GrokUsageProvider: UsageProviding {
    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let session: URLSession
    private let retryPolicy: ProviderRetryPolicy
    private let loadCredential: @Sendable () throws -> GrokCredential
    // Never forward a borrowed credential through redirects to another origin.
    private let redirectPolicy: GrokRedirectPolicy

    init(session: URLSession? = nil, retryPolicy: ProviderRetryPolicy? = nil,
         loadCredential: @escaping @Sendable () throws -> GrokCredential = { try GrokCredentialReader.load() }) {
        let policy = GrokRedirectPolicy()
        self.redirectPolicy = policy
        self.retryPolicy = retryPolicy ?? ProviderRetryPolicy(provider: .grok)
        self.loadCredential = loadCredential
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = session ?? URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        let credential = try loadCredential()
        guard credential.expiresAt > .now else { throw GrokProviderError.expired }
        var request = URLRequest(url: Self.billingURL)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(credential.userID, forHTTPHeaderField: "x-userid")
        request.setValue("headless", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GaugeZ/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw GrokProviderError.offline }
        guard let http = response as? HTTPURLResponse else { throw GrokProviderError.malformedResponse }
        switch http.statusCode {
        case 200...299: break
        case 401: throw GrokProviderError.unauthorized
        case 403: throw GrokProviderError.forbidden
        case 429: throw retryPolicy.throttled(response: http)
        case 500...599: throw GrokProviderError.server(http.statusCode)
        default: throw GrokProviderError.unexpectedStatus(http.statusCode)
        }
        let parsed = try GrokUsageParser.parse(data)
        retryPolicy.succeeded()
        let creditsDesc = parsed.prepaidBalance.map { String(format: " · $%.2f credits", $0 / 100) } ?? ""
        let sessionUsage = GrokSessionReader.latestSessionUsage()
        let costInfo: ProviderCostInfo?
        if sessionUsage != nil || parsed.prepaidBalance != nil {
            let balanceInDollars = parsed.prepaidBalance.map { $0 / 100.0 }
            costInfo = ProviderCostInfo(
                sessionCost: sessionUsage?.costUSD,
                totalTokens: sessionUsage?.totalTokens,
                inputTokens: sessionUsage?.inputTokens,
                outputTokens: sessionUsage?.outputTokens,
                cachedTokens: sessionUsage?.cachedTokens,
                reasoningTokens: sessionUsage?.reasoningTokens,
                modelCalls: sessionUsage?.modelCalls,
                apiDurationSeconds: sessionUsage?.apiDurationSeconds,
                projectName: sessionUsage?.project,
                prepaidBalance: balanceInDollars
            )
        } else {
            costInfo = nil
        }
        return UsageSnapshot(provider: .grok, accountID: credential.email, planName: parsed.plan ?? credential.planName,
                             windows: parsed.windows, observedAt: .now,
                             source: "Grok Build billing · \(parsed.isShared ? "shared Grok allowance" : "account allowance")\(creditsDesc)",
                             health: .live, costInfo: costInfo)
    }
}

private final class GrokRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GrokCredential: Sendable {
    let token: String
    let userID: String
    let email: String?
    let expiresAt: Date
    let planName: String?

    init(token: String, userID: String, email: String?, expiresAt: Date, planName: String? = nil) {
        self.token = token
        self.userID = userID
        self.email = email
        self.expiresAt = expiresAt
        self.planName = planName
    }
}

enum GrokCredentialReader {
    static let defaultScope = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"
    static let inheritedScope = "https://accounts.x.ai/sign-in"

    static func authURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["GROK_HOME"], !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).appendingPathComponent("auth.json") }
        }
        return home.appendingPathComponent(".grok/auth.json")
    }

    static func load(url: URL = authURL()) throws -> GrokCredential {
        guard FileManager.default.fileExists(atPath: url.path) else { throw GrokProviderError.notSignedIn }
        let data: Data
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1_048_576 else {
                throw GrokProviderError.malformedCredential
            }
            data = try Data(contentsOf: url)
        } catch let error as GrokProviderError { throw error }
        catch { throw GrokProviderError.credentialUnreadable }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> GrokCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokProviderError.malformedCredential
        }
        // Match the CLI's default scope and inherited scope. Never pick an arbitrary account
        // or an API key from this multi-scope file, and never execute an auth-provider command.
        guard let value = root[defaultScope] ?? root[inheritedScope] else {
            if root.isEmpty { throw GrokProviderError.notSignedIn }
            throw GrokProviderError.unsupportedAuth
        }
        guard let record = value as? [String: Any] else { throw GrokProviderError.malformedCredential }
        guard let mode = record["auth_mode"] as? String, ["oidc", "external"].contains(mode),
              record["oidc_issuer"] as? String == "https://auth.x.ai" else { throw GrokProviderError.unsupportedAuth }
        guard let token = record["key"] as? String, validHeader(token),
              let userID = record["user_id"] as? String, validHeader(userID),
              let created = (record["create_time"] as? String).flatMap(GrokUsageParser.date) else {
            throw GrokProviderError.malformedCredential
        }
        let expiry: Date
        if let raw = record["expires_at"], !(raw is NSNull) {
            guard let text = raw as? String, let date = GrokUsageParser.date(text) else { throw GrokProviderError.malformedCredential }
            expiry = date
        } else {
            // The CLI's documented fallback for credentials with no server-supplied expiry.
            expiry = created.addingTimeInterval(30 * 86400)
        }
        let planName: String?
        if let claims = jwtPayload(token) {
            if let tier = claims["tier"] as? Int {
                switch tier {
                case 1: planName = "Free"
                case 2: planName = "SuperGrok"
                case 3: planName = "X Premium"
                case 4: planName = "X Premium+"
                default: planName = "Tier \(tier)"
                }
            } else if let tierStr = (claims["subscription_tier"] as? String) ?? (claims["subscriptionTier"] as? String) {
                planName = tierStr
            } else {
                planName = nil
            }
        } else {
            planName = nil
        }
        return GrokCredential(token: token, userID: userID, email: record["email"] as? String, expiresAt: expiry, planName: planName)
    }

    private static func validHeader(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32768 && value.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 && padding < 4 {
            base64.append(String(repeating: "=", count: padding))
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}

enum GrokUsageParser {
    struct Payload {
        let windows: [UsageWindow]
        let plan: String?
        let isShared: Bool
        let prepaidBalance: Double?

        init(windows: [UsageWindow], plan: String?, isShared: Bool, prepaidBalance: Double? = nil) {
            self.windows = windows
            self.plan = plan
            self.isShared = isShared
            self.prepaidBalance = prepaidBalance
        }
    }

    static func parse(_ data: Data) throws -> Payload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokProviderError.malformedResponse
        }
        guard let config = root["config"] as? [String: Any] else {
            if root["config"] is NSNull { throw GrokProviderError.noQuota }
            throw GrokProviderError.malformedResponse
        }
        let shared = config["isUnifiedBillingUser"] as? Bool == true
        let period = config["currentPeriod"] as? [String: Any]
        let type = period?["type"] as? String
        let label: String
        let duration: Int?
        switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY": label = shared ? String(localized: "Shared weekly allowance", bundle: .language) : String(localized: "Weekly allowance", bundle: .language); duration = 10080
        case "USAGE_PERIOD_TYPE_MONTHLY": label = shared ? String(localized: "Shared monthly allowance", bundle: .language) : String(localized: "Monthly allowance", bundle: .language); duration = nil
        default: label = shared ? String(localized: "Shared allowance", bundle: .language) : String(localized: "Included allowance", bundle: .language); duration = nil
        }
        let reset = try optionalDate(period?["end"] ?? config["billingPeriodEnd"])
        let limit = try cents(config["monthlyLimit"])
        let used = try cents(config["used"])
        var windows: [UsageWindow] = []
        if let value = config["creditUsagePercent"], !(value is NSNull) {
            guard let percentage = number(value), percentage >= 0 else { throw GrokProviderError.malformedResponse }
            windows.append(window(id: "included", label: label, percentage: percentage, reset: reset, duration: duration))
        } else if let limit, limit > 0, let used {
            windows.append(window(id: "included", label: String(localized: "Monthly allowance", bundle: .language), percentage: used / limit * 100,
                                  reset: reset, duration: nil))
        } else if period != nil && (type != nil || reset != nil) {
            // When usage is zero in the current period, xAI's billing endpoint omits creditUsagePercent entirely.
            windows.append(window(id: "included", label: label, percentage: 0, reset: reset, duration: duration))
        }
        // A prepaid balance has no quota denominator, so it must never become a percentage.
        // On-demand is a separate allowance only when a real cap and usage are available.
        let onDemandEnabled = (root["onDemandEnabled"] as? Bool) ?? (root["on_demand_enabled"] as? Bool)
        if onDemandEnabled != false,
           let cap = try cents(config["onDemandCap"]), cap > 0 {
            let spent = try cents(config["onDemandUsed"]) ?? used.flatMap { used in limit.map { max(0, used - $0) } }
            if let spent {
                windows.append(window(id: "on-demand", label: String(localized: "On-demand spend", bundle: .language), percentage: spent / cap * 100,
                                      reset: try optionalDate(config["billingPeriodEnd"]), duration: nil))
            }
        }
        guard !windows.isEmpty else { throw GrokProviderError.noQuota }
        let plan = (root["subscriptionTier"] as? String) ?? (root["subscription_tier"] as? String)
        let prepaid = try cents(config["prepaidBalance"])
        return Payload(windows: windows, plan: plan, isShared: shared, prepaidBalance: prepaid)
    }

    private static func window(id: String, label: String, percentage: Double, reset: Date?, duration: Int?) -> UsageWindow {
        UsageWindow(id: id, label: label, usedPercent: min(100, percentage), resetsAt: reset, durationMinutes: duration)
    }

    private static func number(_ raw: Any) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func cents(_ raw: Any?) throws -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let cent = raw as? [String: Any] else { throw GrokProviderError.malformedResponse }
        // Explicit empty Cent is proto3 zero; an absent Cent is unknown.
        guard let value = cent["val"] else { return 0 }
        guard let amount = number(value), amount >= 0 else { throw GrokProviderError.malformedResponse }
        return amount
    }

    private static func optionalDate(_ raw: Any?) throws -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let text = raw as? String, let parsed = date(text) else { throw GrokProviderError.malformedResponse }
        return parsed
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

enum GrokProviderError: LocalizedError, ProviderHealthDescribing {
    case notSignedIn, credentialUnreadable, malformedCredential, unsupportedAuth, expired
    case unauthorized, forbidden, offline, malformedResponse, noQuota, server(Int), unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "No Grok Build login found. Install Grok Build, run `grok login`, then refresh.", bundle: .language)
        case .credentialUnreadable: String(localized: "GaugeZ cannot read Grok Build’s auth.json. Check its file permissions, then retry.", bundle: .language)
        case .malformedCredential: String(localized: "Grok Build’s sign-in file has an unsupported format. Run `grok login` again.", bundle: .language)
        case .unsupportedAuth: String(localized: "Grok usage requires the default xAI account login. Run `grok login`; API keys, legacy web logins, and custom identity providers are not supported.", bundle: .language)
        case .expired: String(localized: "Grok Build’s login has expired. Open Grok Build so it refreshes the login, then retry.", bundle: .language)
        case .unauthorized: String(localized: "Grok rejected the login. Run `grok login` again, then refresh.", bundle: .language)
        case .forbidden: String(localized: "This Grok account cannot access the subscription usage endpoint. Check your account in Grok Build.", bundle: .language)
        case .offline: String(localized: "Grok’s billing service could not be reached. GaugeZ will retry automatically.", bundle: .language)
        case .malformedResponse: String(localized: "Grok returned an unsupported billing response.", bundle: .language)
        case .noQuota: String(localized: "Grok reported no measurable usage allowance for this account.", bundle: .language)
        case .server(let code): String(localized: "Grok’s billing service returned an error (\(code)).", bundle: .language)
        case .unexpectedStatus(let code): String(localized: "Grok’s billing service returned an unexpected status (\(code)).", bundle: .language)
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? String(localized: "Grok Build unavailable", bundle: .language)
        switch self {
        case .notSignedIn, .unauthorized: return .signedOut(message)
        case .credentialUnreadable: return .permissionRequired(message)
        case .expired, .offline, .server: return .stale(message)
        default: return .unavailable(message)
        }
    }
}

enum GrokInstallation {
    static var binaryPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".grok/bin/grok").path,
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
            home.appendingPathComponent(".local/bin/grok").path,
            home.appendingPathComponent(".grok/downloads/grok-macos-aarch64").path
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool {
        binaryPath != nil
    }

    enum LaunchResult: Equatable {
        case opened
        case notInstalled
        case failed(String)
    }

    static let terminalScript: String = {
        let command = "export PATH=$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; grok"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            do script "\(escaped)"
            activate
        end tell
        """
    }()

    /// Starts the installed CLI in Terminal through Apple Events. Hardened runtime requires the
    /// apple-events entitlement and usage string, and the user must allow GaugeZ to control Terminal.
    static func openInTerminal() -> LaunchResult {
        guard isInstalled else { return .notInstalled }
        guard let script = NSAppleScript(source: terminalScript) else { return .failed("Terminal could not be scripted.") }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .opened }
        let code = errorInfo[NSAppleScript.errorNumber] as? Int
        if code == -1743 {
            return .failed("Allow GaugeZ to control Terminal in System Settings › Privacy & Security › Automation, then try again.")
        }
        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Terminal did not accept the command."
        return .failed("Grok Build could not be opened in Terminal: \(message)")
    }
}

struct GrokSessionUsage: Sendable, Equatable {
    let sessionID: String
    let cwd: String
    let project: String
    let costUSD: Double
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let reasoningTokens: Int
    let modelCalls: Int
    let apiDurationSeconds: Int
}

enum GrokSessionReader {
    static func latestSessionUsage(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> GrokSessionUsage? {
        let baseDir: URL
        if let custom = environment["GROK_HOME"], !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            baseDir = URL(fileURLWithPath: expanded)
        } else {
            baseDir = home.appendingPathComponent(".grok")
        }
        let sessionsDir = baseDir.appendingPathComponent("sessions")

        // 1. Try active_sessions.json first
        let activeURL = baseDir.appendingPathComponent("active_sessions.json")
        if let data = try? Data(contentsOf: activeURL),
           let active = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = active.first,
           let sid = first["session_id"] as? String,
           let cwd = first["cwd"] as? String {
            if let usage = readSession(sessionsDir: sessionsDir, cwd: cwd, sid: sid) {
                return usage
            }
        }

        // 2. Try session_search.sqlite
        let sqliteURL = sessionsDir.appendingPathComponent("session_search.sqlite")
        if FileManager.default.fileExists(atPath: sqliteURL.path) {
            if let db = ReadOnlySQLite.open(path: sqliteURL.path) {
                defer { sqlite3_close(db) }
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT session_id, cwd FROM session_docs ORDER BY updated_at DESC LIMIT 1", -1, &stmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(stmt) }
                    if sqlite3_step(stmt) == SQLITE_ROW,
                       let sidPtr = sqlite3_column_text(stmt, 0),
                       let cwdPtr = sqlite3_column_text(stmt, 1) {
                        let sid = String(cString: sidPtr)
                        let cwd = String(cString: cwdPtr)
                        if let usage = readSession(sessionsDir: sessionsDir, cwd: cwd, sid: sid) {
                            return usage
                        }
                    }
                }
            }
        }

        // 3. Fallback: scan sessions directory for most recent updates.jsonl
        guard let workspaceDirs = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        var newestFile: (url: URL, date: Date)?
        for ws in workspaceDirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: ws.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let sessionDirs = try? FileManager.default.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil) else { continue }
            for sdir in sessionDirs {
                let updatesFile = sdir.appendingPathComponent("updates.jsonl")
                if let attrs = try? updatesFile.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                   attrs.isRegularFile == true,
                   let mod = attrs.contentModificationDate {
                    if newestFile == nil || mod > newestFile!.date {
                        newestFile = (updatesFile, mod)
                    }
                }
            }
        }
        if let file = newestFile {
            return parseUpdatesFile(file.url)
        }

        return nil
    }

    static func readSession(sessionsDir: URL, cwd: String, sid: String) -> GrokSessionUsage? {
        let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cwd
        let updatesURL = sessionsDir.appendingPathComponent(encoded).appendingPathComponent(sid).appendingPathComponent("updates.jsonl")
        return parseUpdatesFile(updatesURL, cwd: cwd, sid: sid)
    }

    static func parseUpdatesFile(_ updatesURL: URL, cwd: String? = nil, sid: String? = nil) -> GrokSessionUsage? {
        guard FileManager.default.fileExists(atPath: updatesURL.path) else { return nil }
        guard let attrs = try? updatesURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              attrs.isRegularFile == true,
              let fileSize = attrs.fileSize, fileSize > 0 else { return nil }

        let maxChunk = 65_536
        let data: Data
        if fileSize > maxChunk {
            guard let handle = try? FileHandle(forReadingFrom: updatesURL) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(fileSize - maxChunk))
            data = handle.readDataToEndOfFile()
        } else {
            guard let fileData = try? Data(contentsOf: updatesURL) else { return nil }
            data = fileData
        }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        for line in lines.reversed() {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let params = obj["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed",
                  let usage = update["usage"] as? [String: Any] else { continue }

            let ticks = (usage["costUsdTicks"] as? NSNumber)?.doubleValue ?? 0
            let costUSD = ticks / 10_000_000_000.0
            let totalTokens = (usage["totalTokens"] as? NSNumber)?.intValue ?? 0
            let inputTokens = (usage["inputTokens"] as? NSNumber)?.intValue ?? 0
            let outputTokens = (usage["outputTokens"] as? NSNumber)?.intValue ?? 0
            let cached = (usage["cachedReadTokens"] as? NSNumber)?.intValue ?? 0
            let reasoning = (usage["reasoningTokens"] as? NSNumber)?.intValue ?? 0
            let modelCalls = (usage["modelCalls"] as? NSNumber)?.intValue ?? 0
            let durationMs = (usage["apiDurationMs"] as? NSNumber)?.intValue ?? 0

            let actualCwd = cwd ?? (params["cwd"] as? String ?? "")
            let actualSid = sid ?? (params["sessionId"] as? String ?? "")
            let project: String
            if !actualCwd.isEmpty {
                project = URL(fileURLWithPath: actualCwd).lastPathComponent
            } else {
                // Grok stores each workspace under its percent-encoded cwd; show only the folder name.
                let parentDir = updatesURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                project = URL(fileURLWithPath: parentDir.removingPercentEncoding ?? parentDir).lastPathComponent
            }

            return GrokSessionUsage(
                sessionID: actualSid,
                cwd: actualCwd,
                project: project,
                costUSD: costUSD,
                totalTokens: totalTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedTokens: cached,
                reasoningTokens: reasoning,
                modelCalls: modelCalls,
                apiDurationSeconds: durationMs / 1000
            )
        }
        return nil
    }
}
