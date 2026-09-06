import Foundation
import Security
import SQLite3

private struct Failure: Error, CustomStringConvertible { let description: String }

/// Standalone fixture suite: no real credentials, provider services, or GaugeZ preferences.
@main
struct ProviderRegressionTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(description: message) }
    }
    static func rejects(_ action: () throws -> Void, _ message: String) throws {
        do { try action() } catch { checks += 1; return }
        throw Failure(description: message)
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gaugez-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "GaugeZ.Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try profiles(root)
        try credentials()
        try glm(root)
        try grok(root)
        try grokSessionAndCost(root)
        try await cursor(root)
        try retry(defaults)
        try await networking(root: root, defaults: defaults)
        try await grokNetworking(root: root, defaults: defaults)
        print("Passed \(checks) provider regression checks.")
    }

    static func profiles(_ root: URL) throws {
        let fm = FileManager.default
        for name in [".claude-work/sessions", ".claude-client/projects", ".claude-empty"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent(".claude-file"))
        let profiles = ClaudeProfile.discover(home: root)
        try expect(profiles.map(\.provider.rawValue) == ["claude", "claude-client", "claude-work"], "Discover only used directories in stable order")
        try expect(profiles[0].keychainService == "Claude Code-credentials", "Default service must stay compatible")
        try expect(profiles[1].keychainService != profiles[2].keychainService, "Profiles must have distinct keychain services")
        try expect(profiles[2].sessionsDirectory == root.appendingPathComponent(".claude-work/sessions"), "Profile activity directory")
        let ids = profiles.map(\.provider) + [.glm, .codex]
        let encoded = try JSONEncoder().encode(ids)
        let decoded = try JSONDecoder().decode([ProviderID].self, from: encoded)
        try expect(decoded == ids, "Round-trip profile identities")
        let old = try JSONDecoder().decode(ProviderID.self, from: Data("\"claude\"".utf8))
        try expect(old == .claude, "Decode old cached provider IDs")
        try expect(ProviderID(rawValue: "claude-../bad") == nil, "Reject paths in profile IDs")
        try expect(ProviderID(rawValue: "claude-") == nil, "Reject empty profile slug")
        let credential = Data(#"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":4102444800000}}"#.utf8)
        try credential.write(to: profiles[2].credentialsFile)
        let loaded = try ClaudeCredentialReader.load(profile: profiles[2], match: nil)
        try expect(loaded.accessToken == "fixture", "Read the selected profile's file fallback")
        try rejects({ _ = try ClaudeCredentialReader.load(profile: profiles[1], match: nil) }, "Do not borrow a different profile's credential")
    }

    static func credentials() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = ClaudeKeychain.Match(modifiedAt: now.addingTimeInterval(-100), persistentRef: Data([1]))
        let fresh = ClaudeKeychain.Match(modifiedAt: now, persistentRef: Data([2]))
        let undated = ClaudeKeychain.Match(modifiedAt: nil, persistentRef: Data([3]))
        try expect(ClaudeKeychain.newest(in: [fresh, undated, old]) == fresh, "Newest duplicate wins regardless of enumeration order")
        try expect(ClaudeKeychain.newest(in: [old, fresh]) == fresh, "Newest duplicate wins reverse order")
        try expect(ClaudeKeychain.newest(in: []) == nil, "No keychain match")
        let cache = ClaudeCredentialCache()
        var reads = 0
        let credential = ClaudeCredential(accessToken: "fixture", expiresAt: now.addingTimeInterval(-1), subscriptionType: nil, sourceDescription: "fixture")
        func read() -> ClaudeCredential { reads += 1; return credential }
        _ = try cache.value(stamp: old, now: now, reload: read)
        _ = try cache.value(stamp: old, now: now.addingTimeInterval(10000), reload: read)
        try expect(reads == 1, "Unchanged expired credentials must not prompt again")
        _ = try cache.value(stamp: fresh, now: now, reload: read)
        try expect(reads == 2, "Rotation invalidates cached credentials")
        cache.forget()
        func deny() throws -> ClaudeCredential { reads += 1; throw ClaudeProviderError.keychainDenied(errSecUserCanceled) }
        try rejects({ _ = try cache.value(stamp: fresh, now: now, reload: deny) }, "Record denied access")
        try rejects({ _ = try cache.value(stamp: fresh, now: now.addingTimeInterval(10000), reload: read) }, "Polling must preserve refusal")
        try expect(reads == 3, "No repeated secret read after refusal")
        cache.forget()
        _ = try cache.value(stamp: fresh, now: now, reload: read)
        try expect(reads == 4, "Explicit retry clears refusal")
        cache.forget()
        try rejects({ _ = try cache.value(stamp: nil, now: now, reload: deny) }, "Refusal without a metadata stamp")
        try rejects({ _ = try cache.value(stamp: nil, now: now.addingTimeInterval(10000), reload: read) }, "Missing metadata must not repeat denial prompts")
        _ = try cache.value(stamp: fresh, now: now, reload: read)
        try expect(reads == 6, "New metadata recovers from prior refusal")
        cache.forget()
        _ = try cache.value(stamp: fresh, now: now) { cache.forget(); return read() }
        _ = try cache.value(stamp: fresh, now: now, reload: read)
        try expect(reads == 8, "Forget during a load must discard that result without deadlocking")
        if case .stale = ClaudeProviderError.tokenExpired.providerHealth { checks += 1 }
        else { throw Failure(description: "Expired credentials should retain a stale reading") }
    }

    static func glm(_ root: URL) throws {
        let data = Data(#"{"code":200,"success":true,"data":{"level":"pro","limits":[{"type":"TIME_LIMIT","percentage":4},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":8.1,"nextResetTime":1800000000000},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12.5}]}}"#.utf8)
        let parsed = try GLMUsageParser.parse(data)
        try expect(parsed.windows.map(\.id) == ["session", "weekly", "mcp"], "GLM window order and credit plans")
        try expect(parsed.windows[0].remainingPercent == 87, "GLM remaining percent")
        try expect(parsed.windows[1].resetsAt == Date(timeIntervalSince1970: 1_800_000_000), "GLM milliseconds reset")
        try expect(parsed.windows[2].resetsAt == nil, "Keep MCP allowance with no reset")
        for json in [#"{"code":401,"success":false}"#, #"{"code":200,"success":false,"data":{"limits":[]}}"#,
                     #"{"code":429,"success":true}"#, #"{"code":200,"data":{"limits":[]}}"#,
                     #"{"code":200,"data":{"limits":[{"type":"TIME_LIMIT","percentage":-1}]}}"#,
                     #"{"code":200,"data":{"limits":[{"type":"TIME_LIMIT","percentage":101}]}}"#,
                     #"{"code":200,"data":{"limits":[{"type":"TIME_LIMIT","percentage":1},{"type":"TIME_LIMIT","percentage":2}]}}"#] {
            try rejects({ _ = try GLMUsageParser.parse(Data(json.utf8)) }, "GLM must reject erroneous/empty/invalid responses")
        }
        let file = root.appendingPathComponent("settings.json")
        try Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"test-key","ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}"#.utf8).write(to: file)
        try expect(GLMCredentials.claudeCode(file) == nil, "Do not treat an Anthropic key as GLM")
        try Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"test-key","ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic"}}"#.utf8).write(to: file)
        try expect(GLMCredentials.claudeCode(file)?.baseURL.host == "open.bigmodel.cn", "China key routes to China console")
        try Data(#"{"oauth:zai:access_token":"enc:v1:encrypted"}"#.utf8).write(to: file)
        try expect(GLMCredentials.zcode(file) == nil, "Skip encrypted ZCode credentials")
        try Data(#"{"provider":{"builtin:zai-coding-plan":{"enabled":false,"options":{"apiKey":"fixture","baseURL":"https://api.z.ai"}}}}"#.utf8).write(to: file)
        try expect(GLMCredentials.zcodePlanKey(file) == nil, "Ignore disabled ZCode entries")
        try Data(#"{"zhipu":{"key":"fixture"}}"#.utf8).write(to: file)
        try expect(GLMCredentials.openCode(file)?.baseURL.host == "open.bigmodel.cn", "OpenCode China provider mapping")
        try expect(!GLMCredentials.isZaiHost("api.z.ai.attacker.test"), "Reject lookalike credential hosts")
    }

    static func cursor(_ root: URL) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let launch = now.addingTimeInterval(-3600)
        var row: [String: Any] = ["composerId": "fixture", "name": "Fixture chat", "unfinishedRunAt": now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000,
                                  "conversationCheckpointLastUpdatedAt": now.addingTimeInterval(-10).timeIntervalSince1970 * 1000]
        func parse(_ launch: Date? = launch) throws -> ActivitySession? {
            CursorActivityParser.session(from: try JSONSerialization.data(withJSONObject: row), launchedAt: launch, now: now)
        }
        try expect(try parse()?.state == .working, "Old composer with a recent write is working")
        try expect(try parse(nil) == nil, "Closed Cursor has no live sessions")
        try expect(try parse(now) == nil, "Writes before editor relaunch are stale")
        row["conversationCheckpointLastUpdatedAt"] = now.addingTimeInterval(-901).timeIntervalSince1970 * 1000
        try expect(try parse() == nil, "Abandoned run expires after 15 minutes")
        row.removeValue(forKey: "conversationCheckpointLastUpdatedAt")
        row["lastUpdatedAt"] = now.addingTimeInterval(-10).timeIntervalSince1970 * 1000
        try expect(try parse()?.state == .working, "Fallback to lastUpdatedAt")
        row.removeValue(forKey: "unfinishedRunAt")
        try expect(try parse() == nil, "Finished runs are not working")
        row["hasPendingPlan"] = true
        try expect(try parse()?.state == .waiting, "Pending plan needs input")
        row["unfinishedRunAt"] = now.timeIntervalSince1970 * 1000
        try expect(try parse()?.state == .waiting, "Waiting takes precedence over working")
        let dbURL = root.appendingPathComponent("cursor.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw Failure(description: "Fixture DB failed") }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE composerHeaders(value TEXT, isArchived INTEGER, recency INTEGER);", nil, nil, nil)
        let json = String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO composerHeaders VALUES (?, 0, 1)", -1, &statement, nil)
        sqlite3_bind_text(statement, 1, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(statement)
        sqlite3_finalize(statement)
        let sessions = await ActivityReader().readCursorSessions(launchedAt: launch, store: dbURL)
        try expect(sessions.count == 1 && sessions[0].state == .waiting, "Read Cursor rows from active WAL")
        sqlite3_exec(db, "UPDATE composerHeaders SET isArchived = 1", nil, nil, nil)
        let archived = await ActivityReader().readCursorSessions(launchedAt: launch, store: dbURL)
        try expect(archived.isEmpty, "Archived Cursor chats excluded")
        sqlite3_exec(db, "UPDATE composerHeaders SET isArchived = 0; PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        sqlite3_close(db)
        db = nil
        for sidecar in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + sidecar) }
        let closed = await ActivityReader().readCursorSessions(launchedAt: launch, store: dbURL)
        try expect(closed.count == 1, "Read a WAL database without sidecars and without logging an open failure")
    }

    static func retry(_ defaults: UserDefaults) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let work = ProviderID(rawValue: "claude-work")!
        let first = ProviderRetryPolicy(provider: .claude, defaults: defaults, now: { now })
        let second = ProviderRetryPolicy(provider: work, defaults: defaults, now: { now })
        let response = HTTPURLResponse(url: URL(string: "https://fixture.test")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "0"])!
        let error = first.throttled(response: response)
        try expect(error.until == now.addingTimeInterval(60), "Retry-After zero still waits")
        try expect(second.deadline == nil, "Backoff isolated per account")
        let relaunched = ProviderRetryPolicy(provider: .claude, defaults: defaults, now: { now })
        try expect(relaunched.deadline == first.deadline, "Backoff persists across provider instances")
        let elapsed = ProviderRetryPolicy(provider: .claude, defaults: defaults, now: { now.addingTimeInterval(61) })
        try expect(elapsed.deadline == nil, "Expired deadline stops blocking")
        try elapsed.check()
        let next = first.throttled(response: response)
        try expect(next.until == now.addingTimeInterval(120), "Consecutive throttles increase delay")
        first.succeeded()
        try expect(first.deadline == nil, "Successful reading clears backoff")
    }

    static func grok(_ root: URL) throws {
        let modern = Data(#"{"config":{"creditUsagePercent":42.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2027-01-08T00:00:00Z"},"isUnifiedBillingUser":true,"onDemandCap":{"val":1000},"onDemandUsed":{"val":250},"monthlyLimit":{"val":100},"used":{"val":99}}}"#.utf8)
        let parsed = try GrokUsageParser.parse(modern)
        try expect(parsed.windows[0].remainingPercent == 57, "Grok prefers current percent over legacy cents")
        try expect(parsed.windows[0].label == "Shared weekly allowance", "Shared quota is labeled across Grok products")
        try expect(parsed.windows[0].durationMinutes == 10080, "Weekly duration")
        try expect(parsed.windows[0].resetsAt == GrokUsageParser.date("2027-01-08T00:00:00Z"), "Current period reset")
        try expect(parsed.windows[1].remainingPercent == 75, "On-demand stays a separate budget")
        try expect(parsed.windows[1].resetsAt == nil, "Do not give on-demand the shared weekly reset")
        let legacy = try GrokUsageParser.parse(Data(#"{"config":{"monthlyLimit":{"val":2000},"used":{"val":500},"billingPeriodEnd":"2027-02-01T00:00:00Z"}}"#.utf8))
        try expect(legacy.windows[0].remainingPercent == 75, "Legacy monthly allowance ratio")
        try expect(legacy.windows[0].resetsAt != nil, "Legacy reset date")
        let zero = try GrokUsageParser.parse(Data(#"{"config":{"monthlyLimit":{"val":2000},"used":{}}}"#.utf8))
        try expect(zero.windows[0].remainingPercent == 100, "Explicit empty proto Cent means zero")
        let over = try GrokUsageParser.parse(Data(#"{"config":{"creditUsagePercent":150}}"#.utf8))
        try expect(over.windows[0].remainingPercent == 0, "Overage clamps at exhausted")
        let monthly = try GrokUsageParser.parse(Data(#"{"config":{"creditUsagePercent":0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY"}}}"#.utf8))
        try expect(monthly.windows[0].label == "Monthly allowance" && monthly.windows[0].remainingPercent == 100, "Explicit zero and monthly period")
        let disabled = try GrokUsageParser.parse(Data(#"{"on_demand_enabled":false,"config":{"creditUsagePercent":3,"onDemandCap":{"val":1000},"onDemandUsed":{"val":50}}}"#.utf8))
        try expect(disabled.windows.count == 1, "Skip disabled on-demand")
        let zeroUsageWeekly = try GrokUsageParser.parse(Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-09-09T06:57:11Z"},"isUnifiedBillingUser":true,"onDemandCap":{"val":0},"prepaidBalance":{"val":4000}},"subscriptionTier":"X Premium"}"#.utf8))
        try expect(zeroUsageWeekly.windows[0].remainingPercent == 100, "Zero usage weekly period reports 100% remaining")
        try expect(zeroUsageWeekly.windows[0].label == "Shared weekly allowance", "Zero usage weekly period has shared label")
        try expect(zeroUsageWeekly.plan == "X Premium", "Read camelCase subscriptionTier")
        try expect(zeroUsageWeekly.prepaidBalance == 4000, "Read prepaidBalance")
        for json in ["{}", #"{"config":null}"#, #"{"config":{}}"#,
                     #"{"config":{"monthlyLimit":{"val":1000}}}"#,
                     #"{"config":{"monthlyLimit":{},"used":{}}}"#,
                     #"{"config":{"prepaidBalance":{"val":1000}}}"#,
                     #"{"config":{"creditUsagePercent":true}}"#,
                     #"{"config":{"creditUsagePercent":-1}}"#,
                     #"{"config":{"creditUsagePercent":"20"}}"#,
                     #"{"config":{"creditUsagePercent":20,"currentPeriod":{"end":"bad"}}}"#] {
            try rejects({ _ = try GrokUsageParser.parse(Data(json.utf8)) }, "Missing/invalid Grok data must not become free quota")
        }
        var record: [String: Any] = ["key": "fixture-grok", "auth_mode": "oidc", "oidc_issuer": "https://auth.x.ai",
                                     "user_id": "fixture-user", "create_time": "2027-01-01T00:00:00Z", "expires_at": "2027-01-02T00:00:00Z"]
        func auth(_ scope: String = GrokCredentialReader.defaultScope) throws -> Data {
            try JSONSerialization.data(withJSONObject: [scope: record])
        }
        let credential = try GrokCredentialReader.decode(auth())
        try expect(credential.token == "fixture-grok" && credential.userID == "fixture-user", "Actual GrokAuth map uses key and user_id, not access_token")
        try expect(credential.expiresAt == GrokUsageParser.date("2027-01-02T00:00:00Z"), "Honor server expiry")
        record.removeValue(forKey: "expires_at")
        let fallback = try GrokCredentialReader.decode(auth())
        try expect(fallback.expiresAt == GrokUsageParser.date("2027-01-31T00:00:00Z"), "30-day legacy expiry fallback")
        let inherited = try GrokCredentialReader.decode(auth(GrokCredentialReader.inheritedScope))
        try expect(inherited.token == "fixture-grok", "Inherited scope accepts first-party OIDC")
        for mode in ["api_key", "web_login", "grok"] {
            record["auth_mode"] = mode
            try rejects({ _ = try GrokCredentialReader.decode(auth()) }, "Reject unsupported login mode")
        }
        record["auth_mode"] = "external"
        record["oidc_issuer"] = "https://idp.example.test"
        try rejects({ _ = try GrokCredentialReader.decode(auth()) }, "Never forward third-party login credentials")
        record["oidc_issuer"] = "https://auth.x.ai"
        record["key"] = "bad\r\nheader"
        try rejects({ _ = try GrokCredentialReader.decode(auth()) }, "Reject credential header injection")
        record["key"] = "fixture-grok"
        try rejects({ _ = try GrokCredentialReader.decode(auth("other-account")) }, "Do not choose arbitrary scoped accounts")
        let custom = GrokCredentialReader.authURL(home: root, environment: ["GROK_HOME": root.path])
        try expect(custom == root.appendingPathComponent("auth.json"), "Respect explicit GROK_HOME")
        try expect(GrokCredentialReader.authURL(home: root, environment: [:]) == root.appendingPathComponent(".grok/auth.json"), "Default home path")
        try rejects({ _ = try GrokCredentialReader.load(url: custom) }, "No local installation returns no login")
        try auth().write(to: custom)
        let disk = try GrokCredentialReader.load(url: custom)
        try expect(disk.token == "fixture-grok", "Read scoped credential file")
        record["key"] = "rotated-fixture"
        try auth().write(to: custom)
        let rotated = try GrokCredentialReader.load(url: custom)
        try expect(rotated.token == "rotated-fixture", "Pick up CLI token rotation on next read")

        // Test JWT tier claim decoding
        let dummyPayload = try JSONSerialization.data(withJSONObject: ["tier": 3])
        let base64Payload = dummyPayload.base64EncodedString()
        record["key"] = "header.\(base64Payload).signature"
        let jwtCred = try GrokCredentialReader.decode(auth())
        try expect(jwtCred.planName == "X Premium", "Decode X Premium from JWT tier 3")
    }

    static func grokSessionAndCost(_ root: URL) throws {
        // 1. Test ProviderCostInfo formatting
        let costInfo = ProviderCostInfo(
            sessionCost: 0.0109769,
            totalTokens: 55755,
            inputTokens: 55058,
            outputTokens: 697,
            cachedTokens: 33152,
            reasoningTokens: 140,
            modelCalls: 3,
            apiDurationSeconds: 15,
            projectName: "zyork",
            prepaidBalance: 40.0
        )
        try expect(costInfo.formattedCost == "$0.0110", "Sub-cent cost formats with 4 decimals")
        try expect(costInfo.formattedBalance == "$40.00", "Prepaid balance formats as dollar amount")
        try expect(costInfo.sessionDetailLine == "55.8k tokens · 3 calls · 15s · zyork", "Session detail line includes tokens, calls, duration, project")

        let largerCost = ProviderCostInfo(sessionCost: 1.25)
        try expect(largerCost.formattedCost == "$1.25", "Standard cost formats with 2 decimals")

        // 2. Test GrokSessionReader.parseUpdatesFile with synthetic session log
        let updatesURL = root.appendingPathComponent("test-updates.jsonl")
        let logLine = #"{"timestamp":1788683674,"method":"_x.ai/session/update","params":{"sessionId":"test-session-123","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":55058,"outputTokens":697,"totalTokens":55755,"cachedReadTokens":33152,"reasoningTokens":140,"modelCalls":3,"apiDurationMs":15149,"costUsdTicks":109769000}}}}"#
        try logLine.write(to: updatesURL, atomically: true, encoding: .utf8)
        let parsed = GrokSessionReader.parseUpdatesFile(updatesURL, cwd: "/path/to/myproject", sid: "test-session-123")
        try expect(parsed != nil, "Parse Grok updates.jsonl")
        try expect(parsed?.costUSD != nil && abs(parsed!.costUSD - 0.0109769) < 0.000001, "Cost converted from ticks")
        try expect(parsed?.totalTokens == 55755, "Total tokens matches")
        try expect(parsed?.inputTokens == 55058, "Input tokens matches")
        try expect(parsed?.cachedTokens == 33152, "Cached tokens matches")
        try expect(parsed?.outputTokens == 697, "Output tokens matches")
        try expect(parsed?.reasoningTokens == 140, "Reasoning tokens matches")
        try expect(parsed?.modelCalls == 3, "Model calls count matches")
        try expect(parsed?.apiDurationSeconds == 15, "API duration seconds matches")
        try expect(parsed?.project == "myproject", "Project name extracted from cwd")

        let workspace = root.appendingPathComponent("%2FUsers%2Ffixture%2FDocuments%2Fmyproject/session-1")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try logLine.write(to: workspace.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        let scanned = GrokSessionReader.parseUpdatesFile(workspace.appendingPathComponent("updates.jsonl"))
        try expect(scanned?.project == "myproject", "Scanned session shows the folder name, not the full path")

        // 3. Test AppleScript compilation
        var compileError: NSDictionary?
        let script = NSAppleScript(source: GrokInstallation.terminalScript)
        try expect(script != nil, "AppleScript allocated")
        script?.compileAndReturnError(&compileError)
        try expect(compileError == nil, "AppleScript compiles without syntax errors")
    }

    static func grokNetworking(root: URL, defaults: UserDefaults) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let policy = ProviderRetryPolicy(provider: .grok, defaults: defaults)
        let provider = GrokUsageProvider(session: session, retryPolicy: policy, loadCredential: {
            GrokCredential(token: "grok-fixture", userID: "fixture-user", email: nil, expiresAt: .distantFuture)
        })
        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, #"{"config":{"creditUsagePercent":30}}"#)]
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.provider == .grok && snapshot.remainingPercent == 70, "Grok provider snapshot")
        let request = FixtureProtocol.requests.last!
        try expect(request.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/billing?format=credits", "Official billing route")
        try expect(request.httpMethod == "GET" && request.httpBody == nil, "Read-only billing request")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer grok-fixture", "Bearer authentication")
        try expect(request.value(forHTTPHeaderField: "X-XAI-Token-Auth") == "xai-grok-cli", "CLI token auth header")
        try expect(request.value(forHTTPHeaderField: "x-userid") == "fixture-user", "User identity header")
        FixtureProtocol.responses = [(401, "{}"), (200, #"{"config":{"creditUsagePercent":20}}"#)]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Grok 401") }
        catch GrokProviderError.unauthorized { checks += 1 }
        let recovered = try await provider.fetchSnapshot()
        try expect(recovered.remainingPercent == 80, "Retry recovers after rejected credentials")
        FixtureProtocol.responses = [(429, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Grok throttle") }
        catch is ProviderRetryError { checks += 1 }
        try expect(policy.deadline != nil, "Grok persists server backoff")
        let count = FixtureProtocol.requests.count
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected local backoff") }
        catch is ProviderRetryError { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No network request during backoff")
        policy.reset()
        let expired = GrokUsageProvider(session: session, retryPolicy: policy, loadCredential: {
            GrokCredential(token: "fixture", userID: "fixture-user", email: nil, expiresAt: .distantPast)
        })
        do { _ = try await expired.fetchSnapshot(); throw Failure(description: "Expected expired token") }
        catch GrokProviderError.expired { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "Expired credentials never sent")
    }

    static func networking(root: URL, defaults: UserDefaults) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        FixtureProtocol.responses = [(500, "{}"), (200, #"{"five_hour":{"utilization":30,"resets_at":"2027-01-01T00:00:00Z"}}"#), (200, "{}")]
        let profile = ClaudeProfile(provider: ProviderID(rawValue: "claude-work")!, home: root)
        let provider = ClaudeUsageProvider(profile: profile, session: session,
            retryPolicy: ProviderRetryPolicy(provider: profile.provider, defaults: defaults),
            loadCredentials: { ClaudeCredential(accessToken: "fixture", expiresAt: .distantFuture, subscriptionType: nil, sourceDescription: "fixture") },
            selectedSource: { .desktop })
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected initial server failure") }
        catch ClaudeProviderError.server { checks += 1 }
        let recovered = try await provider.fetchSnapshot()
        try expect(recovered.provider == profile.provider && recovered.remainingPercent == 70, "Next Claude poll recovers and preserves account identity")
        FixtureProtocol.responses = [(200, #"{"code":401,"success":false}"#)]
        let glm = GLMUsageProvider(session: session, retryPolicy: ProviderRetryPolicy(provider: .glm, defaults: defaults),
                                  loadCredentials: { .init(token: "fixture", baseURL: URL(string: "https://api.z.ai")!, source: "fixture") })
        do { _ = try await glm.fetchSnapshot(); throw Failure(description: "Expected envelope auth failure") }
        catch GLMProviderError.unauthorized { checks += 1 }
        FixtureProtocol.responses = [(200, #"{"code":429,"success":false}"#)]
        do { _ = try await glm.fetchSnapshot(); throw Failure(description: "Expected envelope throttle") }
        catch is ProviderRetryError { checks += 1 }
        try expect(ProviderRetryPolicy(provider: .glm, defaults: defaults).deadline != nil, "Envelope throttle persists a deadline")
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(Int, String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard !Self.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, json) = Self.responses.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
