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
        try await portedFeatures(root, defaults)
        try profiles(root)
        try credentials()
        try keychainTransient()
        try claudeResponseShapes()
        try resetCopy()
        try glm(root)
        try grok(root)
        try grokSessionAndCost(root)
        try await grokActivity(root)
        try await inferredActivity(root)
        try elapsedAndCaps()
        try releaseNotes()
        try openCodeParsing(root)
        try await openCodeNetworking(root: root, defaults: defaults)
        try await cursor(root)
        try retry(defaults)
        try codexParsing(root)
        try await codexNetworking(root: root, defaults: defaults)
        try await networking(root: root, defaults: defaults)
        try await grokNetworking(root: root, defaults: defaults)
        print("Passed \(checks) provider regression checks.")
    }

    static func portedFeatures(_ root: URL, _ defaults: UserDefaults) async throws {
        let hosts = "github.com:\n    user: active\n    oauth_token: host-token\n    users:\n        old:\n            oauth_token: wrong-token\nother.example:\n    oauth_token: other-token\n"
        var commands = 0
        func command() -> String? { commands += 1; return "cli-token" }
        let env = try GitHubCopilotCredentials.load(environment: ["GH_TOKEN": " env-token "], hosts: hosts, command: command)
        try expect(env.token == "env-token" && commands == 0, "Copilot environment takes precedence")
        let host = try GitHubCopilotCredentials.load(environment: [:], hosts: hosts, command: command)
        try expect(host.token == "host-token" && host.username == "active" && commands == 0, "Copilot active host token excludes nested inactive accounts")
        let nestedHosts = "github.com:\n    user: active\n    users:\n        active:\n            oauth_token: active-token\n        old:\n            oauth_token: wrong-token\n"
        let nested = try GitHubCopilotCredentials.load(environment: [:], hosts: nestedHosts, command: command)
        try expect(nested.token == "active-token" && commands == 0, "Multi-account hosts uses active account without invoking CLI")
        let cli = try GitHubCopilotCredentials.load(environment: [:], hosts: nil, command: command)
        try expect(cli.token == "cli-token" && commands == 1, "Copilot CLI fallback")
        try rejects({ _ = try GitHubCopilotCredentials.load(environment: [:], hosts: nil, command: { nil }) }, "Copilot missing sign-in")
        let quota = #"{"quota_reset_date":"2027-01-01T00:00:00Z","quota_snapshots":{"chat":{"unlimited":true,"entitlement":100},"completions":{"entitlement":0,"remaining":0},"premium_interactions":{"entitlement":1000,"remaining":3},"future":{"entitlement":10,"used":2}}}"#
        let windows = try GitHubCopilotUsage.windows(from: Data(quota.utf8))
        try expect(windows.map(\.id) == ["premium_interactions", "future"], "Copilot ordering and unmetered filtering")
        try expect(abs(windows[0].remainingPercent - 0.3) < 0.00001 && windows[0].resetsAt != nil, "Copilot exact fractions and resets")
        try rejects({ _ = try GitHubCopilotUsage.windows(from: Data(#"{"quota_snapshots":{"chat":{"remaining":3}}}"#.utf8)) }, "No invented quota denominator")
        for (value, copy) in [(0.0, "0"), (0.03, "<0.1"), (0.3, "0.3"), (0.99, "0.9"), (99.7, "99.7"), (99.99, ">99.9"), (100, "100")] {
            try expect(PercentCopy.text(value) == copy, "Exact endpoint display for \(value)")
        }
        let oldCache = Data(#"{"id":"old","label":"Old","usedPercent":80,"resetsAt":null,"durationMinutes":null}"#.utf8)
        try expect(try JSONDecoder().decode(UsageWindow.self, from: oldCache).remainingPercent == 20, "Integer cache migrates to Double")
        let encoded = try JSONEncoder().encode(windows)
        try expect(try JSONDecoder().decode([UsageWindow].self, from: encoded) == windows, "Fractional cache round trip")

        func snapshot(_ used: Double, health: ProviderHealth = .live, provider: ProviderID = .copilot) -> UsageSnapshot {
            UsageSnapshot(provider: provider, accountID: nil, planName: nil,
                          windows: [UsageWindow(id: "window", label: "Monthly", usedPercent: used, resetsAt: nil, durationMinutes: nil)],
                          observedAt: .now, source: "fixture", health: health)
        }
        var detector = ThresholdNotifier()
        try expect(detector.observe(snapshot(79.9)).isEmpty, "No premature 80% alert")
        try expect(detector.observe(snapshot(80)).map(\.threshold) == [80], "20% left alert")
        try expect(detector.observe(snapshot(99.7)).isEmpty, "Sub-1% is not exhausted")
        try expect(detector.observe(snapshot(100)).map(\.threshold) == [100], "Exhaustion alert")
        try expect(detector.observe(snapshot(99)).isEmpty && detector.observe(snapshot(100)).isEmpty, "100% jitter does not re-alert")
        try expect(detector.observe(snapshot(0, health: .stale("old"))).isEmpty && detector.observe(snapshot(100)).isEmpty, "Stale snapshots cannot reset crossing memory")
        _ = detector.observe(snapshot(79))
        try expect(detector.observe(snapshot(100)).map(\.threshold) == [80, 100], "New cycle crosses both levels")
        _ = detector.observe(snapshot(80, provider: .cursor), muted: true)
        try expect(detector.observe(snapshot(90, provider: .cursor)).isEmpty, "Unmuting does not replay alerts")
        try expect(detector.observe(snapshot(80, provider: .claude)).count == 1, "Provider crossing memories isolated")

        func activity(_ state: ActivitySession.State, id: String = "one", provider: ProviderID = .claude) -> ActivitySession {
            ActivitySession(id: id, provider: provider, name: "Fixture", project: "Fixture", state: state, waitingReason: nil)
        }
        var watcher = SessionCompletionWatcher()
        try expect(watcher.absorb([activity(.idle), activity(.working, id: "two")]).isEmpty, "Initial sessions stay quiet")
        try expect(watcher.absorb([activity(.idle), activity(.waiting, id: "two")]).first?.reason == .blocked, "Working to waiting")
        try expect(watcher.absorb([activity(.working), activity(.idle, id: "two")]).isEmpty, "Waiting to idle is not completion")
        try expect(watcher.absorb([activity(.idle)]).first?.reason == .finished, "Working to idle")
        _ = watcher.absorb([activity(.working)])
        try expect(watcher.absorb([]).isEmpty && watcher.absorb([activity(.idle)]).isEmpty, "Vanished and rediscovered sessions stay quiet")
        _ = watcher.absorb([activity(.working)])
        try expect(watcher.absorb([activity(.unknown)]).isEmpty, "Unknown is not completion")

        let config = root.appendingPathComponent("cli-config.json")
        try Data(#"{"authInfo":{"authId":"workos|fixture","userId":123,"email":"fixture@example.test"}}"#.utf8).write(to: config)
        let token = "header." + Data(#"{"sub":"fallback","exp":4102444800}"#.utf8).base64EncodedString() + ".signature"
        let cursor = try CursorLocalSession.load(editorStore: root.appendingPathComponent("missing-db"), agentConfig: config, agentToken: { token })
        try expect(cursor.userID == "workos|fixture" && cursor.appVersion == "CLI", "Cursor CLI works with no editor")
        try expect(cursor.cookieValue.contains("%3A%3A"), "Cursor cookie pairs account and JWT")
        try rejects({ _ = try CursorLocalSession.loadAgent(token: token, config: config, now: .distantFuture) }, "Expired CLI token rejected")
        let team = try CursorUsageParser.snapshot(fromSummary: Data(#"{"membershipType":"enterprise","individualUsage":{"overall":{"enabled":true,"used":6907,"limit":45000}},"teamUsage":{"onDemand":{"enabled":true,"used":0,"limit":1000000}}}"#.utf8), account: nil, membership: nil, source: "fixture")
        try expect(team.windows.map(\.id) == ["cursor-overall", "cursor-team-on-demand"], "Enterprise individual and shared budgets retained")
        try expect(abs(team.windows[0].usedPercent - 6907.0 / 45000 * 100) < 0.0001, "Enterprise ratio preserved")
        let precise = try CursorUsageParser.snapshot(fromSummary: Data(#"{"individualUsage":{"plan":{"enabled":true,"totalPercentUsed":99.7}}}"#.utf8), account: nil, membership: nil, source: "fixture")
        try expect(precise.remainingPercent! > 0 && PercentCopy.text(precise.remainingPercent!) == "0.3", "Cursor fractional remainder")

        let googleStored = Data(#"{"auth_method":"consumer","token":{"access_token":"fixture","expiry":"2027-01-01T07:00:00.123+07:00"}}"#.utf8)
        let credential = AntigravityCredentials.decode(Data(("go-keyring-base64:" + googleStored.base64EncodedString()).utf8))
        try expect(credential?.accessToken == "fixture" && credential?.expiresAt == AntigravityCredentials.parse("2027-01-01T00:00:00.123Z"), "Antigravity Go keyring and timezone decoding")
        let googleQuota = #"{"quotaGroups":[{"buckets":[{"name":"weekly","displayName":"Weekly","limit":1000,"used":997,"resetTime":"2027-01-01T00:00:00Z"}]}]}"#
        let googleWindows = try AntigravityQuotaParser.remoteWindows(from: Data(googleQuota.utf8))
        try expect(googleWindows.count == 1 && googleWindows[0].remainingPercent > 0, "Google remote quota shape")
        try rejects({ _ = try AntigravityQuotaParser.remoteWindows(from: Data(#"{"buckets":[{"name":"bad","used":9,"limit":0}]}"#.utf8)) }, "Google rejects absent denominator")
        let logs = root.appendingPathComponent("brain/session/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = ISO8601DateFormatter().string(from: now)
        let yesterday = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86400))
        try Data("{\"source\":\"MODEL\",\"created_at\":\"\(today)\"}\n{\"source\":\"USER\",\"created_at\":\"\(today)\"}\ninvalid\n{\"source\":\"MODEL\",\"created_at\":\"\(yesterday)\"}\n".utf8).write(to: logs.appendingPathComponent("transcript.jsonl"))
        let count = AntigravityActivity.read(root: root.appendingPathComponent("brain"), now: now)
        try expect(count.requestsToday == 1 && count.lastRequest == now, "Derived count includes only today's MODEL turns")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, quota), (401, "{}"), (429, "{}")]
        let copilot = GitHubCopilotProvider(session: session, retryPolicy: ProviderRetryPolicy(provider: .copilot, defaults: defaults), loadCredentials: { GitHubCopilotCredentials(token: "fixture", username: nil, source: "fixture") })
        let result = try await copilot.fetchSnapshot()
        try expect(result.headlineWindowID == "premium_interactions", "Copilot headline follows premium requests")
        try expect(FixtureProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture", "Copilot bearer header")
        do { _ = try await copilot.fetchSnapshot(); throw Failure(description: "Expected Copilot auth rejection") } catch CopilotProviderError.signedOut { checks += 1 }
        do { _ = try await copilot.fetchSnapshot(); throw Failure(description: "Expected Copilot throttle") } catch is ProviderRetryError { checks += 1 }
        let attempts = FixtureProtocol.requests.count
        do { _ = try await copilot.fetchSnapshot(); throw Failure(description: "Expected backoff") } catch is ProviderRetryError { checks += 1 }
        try expect(FixtureProtocol.requests.count == attempts, "Copilot backoff prevents network call")

        FixtureProtocol.responses = [(200, googleQuota), (403, "{}")]
        let antigravity = AntigravityUsageProvider(remoteSession: session, retryPolicy: ProviderRetryPolicy(provider: .antigravity, defaults: defaults), localQuota: { throw AntigravityProviderError.noReachableServer }, loadCredentials: { AntigravityCredentials(accessToken: "fixture", expiresAt: .distantFuture, authMethod: "licensed") }, readActivity: { AntigravityActivity(requestsToday: 3, lastRequest: .now) })
        let remote = try await antigravity.fetchSnapshot()
        try expect(remote.windows.count == 1 && remote.source == "Google Cloud Code quota", "Closed Antigravity tries remote quota")
        let derived = try await antigravity.fetchSnapshot()
        try expect(derived.derivedRequestCount == 3 && derived.windows.isEmpty && derived.remainingPercent == nil, "403 falls back to derived count without inventing a percentage")
        let asked = FixtureProtocol.requests.count
        let again = try await antigravity.fetchSnapshot()
        try expect(FixtureProtocol.requests.count == asked && again.derivedRequestCount == 3, "A refused token is not sent to Google again until it rotates")
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

    /// -25320 is what the Keychain answers right after waking; it says nothing about the grant.
    static func keychainTransient() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard case .keychainUnavailable = ClaudeKeychain.failure(for: ClaudeKeychain.darkWakeStatus) else {
            throw Failure(description: "Dark-wake status is transient, not a refusal")
        }
        guard case .keychainDenied = ClaudeKeychain.failure(for: errSecAuthFailed) else {
            throw Failure(description: "Auth failure stays a refusal")
        }
        guard case .stale = ClaudeProviderError.keychainUnavailable(ClaudeKeychain.darkWakeStatus).providerHealth else {
            throw Failure(description: "A transient Keychain failure keeps the last reading as stale")
        }
        checks += 3
        let cache = ClaudeCredentialCache()
        let stamp = ClaudeKeychain.Match(modifiedAt: now, persistentRef: Data([9]))
        var reads = 0
        func darkWake() throws -> ClaudeCredential { reads += 1; throw ClaudeProviderError.keychainUnavailable(ClaudeKeychain.darkWakeStatus) }
        try rejects({ _ = try cache.value(stamp: stamp, now: now, reload: darkWake) }, "Transient failure surfaces")
        try rejects({ _ = try cache.value(stamp: stamp, now: now.addingTimeInterval(60), reload: darkWake) }, "Transient failure surfaces again")
        try expect(reads == 2, "A transient failure is retried on the next poll rather than pinned")
        let credential = ClaudeCredential(accessToken: "fixture", expiresAt: nil, subscriptionType: nil, sourceDescription: "fixture")
        let loaded = try cache.value(stamp: stamp, now: now.addingTimeInterval(120)) { reads += 1; return credential }
        try expect(loaded.accessToken == "fixture" && reads == 3, "Recovers without a forget or a rotation")
    }

    static func claudeResponseShapes() throws {
        let both = Data(#"{"limits":[{"kind":"session","percent":30,"resets_at":"2027-01-01T00:00:00Z"},{"kind":"weekly_all","percent":10},{"kind":"weekly_opus","percent":5}],"five_hour":{"utilization":30,"resets_at":"2027-01-01T00:00:00Z"},"seven_day":{"utilization":10}}"#.utf8)
        let merged = try ClaudeUsageParser.windows(from: both)
        try expect(merged.map(\.id) == ["five_hour", "seven_day", "seven_day_opus"], "Both shapes merge to one window per id")
        try expect(merged[0].usedPercent == 30 && merged[0].resetsAt == GrokUsageParser.date("2027-01-01T00:00:00Z"), "Array shape carries value and reset")
        let arrayOnly = try ClaudeUsageParser.windows(from: Data(#"{"limits":[{"kind":"session","percent":42}]}"#.utf8))
        try expect(arrayOnly.count == 1 && arrayOnly[0].id == "five_hour" && arrayOnly[0].label == "5-hour limit", "Array-only response still yields the session window")
        let rolledOver = try ClaudeUsageParser.windows(from: Data(#"{"limits":[{"kind":"weekly_all","percent":10}],"five_hour":{"utilization":0,"resets_at":"2027-01-01T00:00:00Z"}}"#.utf8))
        try expect(rolledOver.map(\.id) == ["five_hour", "seven_day"], "A window missing from the array is taken from the named object")
        try rejects({ _ = try ClaudeUsageParser.windows(from: Data(#"{"limits":[{"kind":"session","percent":140}]}"#.utf8)) }, "Out-of-range array percent is rejected")
    }

    static func resetCopy() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let monthOut = now.addingTimeInterval(26 * 86_400)
        try expect(ResetCopy.daysApart(from: now, to: monthOut, calendar: calendar) == 26, "Calendar days apart")
        try expect(ResetCopy.absolute(monthOut, now: now, calendar: calendar) == monthOut.formatted(.dateTime.month(.abbreviated).day()), "A reset weeks away shows the date, not a weekday")
        let thisWeek = now.addingTimeInterval(3 * 86_400)
        try expect(ResetCopy.absolute(thisWeek, now: now, calendar: calendar) == thisWeek.formatted(.dateTime.weekday(.abbreviated).hour().minute()), "A reset this week keeps the weekday")
        let soon = now.addingTimeInterval(3 * 3600)
        try expect(ResetCopy.absolute(soon, now: now, calendar: calendar) == soon.formatted(date: .omitted, time: .shortened), "A reset today is a time only")
        let sevenDays = calendar.date(byAdding: .day, value: 7, to: now)!
        try expect(ResetCopy.absolute(sevenDays, now: now, calendar: calendar) == sevenDays.formatted(.dateTime.month(.abbreviated).day()), "Seven calendar days is already a date")
    }

    static func glm(_ root: URL) throws {
        let data = Data(#"{"code":200,"success":true,"data":{"level":"pro","limits":[{"type":"TIME_LIMIT","percentage":4},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":8.1,"nextResetTime":1800000000000},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12.5}]}}"#.utf8)
        let parsed = try GLMUsageParser.parse(data)
        try expect(parsed.windows.map(\.id) == ["session", "weekly", "mcp"], "GLM window order and credit plans")
        try expect(parsed.windows[0].remainingPercent == 87.5, "GLM remaining percent")
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
        try Data(#"{"provider":{"builtin:zai-coding-plan":{"options":{"apiKey":"fixture"}}}}"#.utf8).write(to: file)
        try expect(GLMCredentials.zcodePlanKey(file)?.baseURL.host == "api.z.ai", "A plan key without a base URL is the global console")
        try Data(#"{"provider":{"builtin:zai-coding-plan":{"options":{"apiKey":"fixture","baseURL":"https://api.openai.com/v1"}}}}"#.utf8).write(to: file)
        try expect(GLMCredentials.zcodePlanKey(file) == nil, "A plan entry aimed elsewhere is not a GLM key")
        let tolerant = try GLMUsageParser.parse(Data(#"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12},{"type":"NEW_LIMIT","percentage":50},{"type":"NEW_LIMIT","percentage":60}]}}"#.utf8))
        try expect(tolerant.windows.map(\.id) == ["session", "new_limit-1", "new_limit-2"], "Unknown window shapes are kept rather than dropped")
        try Data(#"{"zhipu":{"key":"fixture"}}"#.utf8).write(to: file)
        try expect(GLMCredentials.openCode(file)?.baseURL.host == "open.bigmodel.cn", "OpenCode China provider mapping")
        try expect(!GLMCredentials.isZaiHost("api.z.ai.attacker.test"), "Reject lookalike credential hosts")
    }

    static func grokActivity(_ root: URL) async throws {
        let home = root.appendingPathComponent("grok-home")
        let cwd = "/Users/fixture/Documents/my project"
        let sid = "session-fixture"
        let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let sessionDir = home.appendingPathComponent(".grok/sessions").appendingPathComponent(encoded).appendingPathComponent(sid)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let now = Date()
        let iso = ISO8601DateFormatter()
        func writeActive(openedAt: Date) throws {
            let rows: [[String: Any]] = [["session_id": sid, "pid": Int(ProcessInfo.processInfo.processIdentifier), "cwd": cwd, "opened_at": iso.string(from: openedAt)]]
            try JSONSerialization.data(withJSONObject: rows).write(to: home.appendingPathComponent(".grok/active_sessions.json"))
        }
        try writeActive(openedAt: now)
        let reader = ActivityReader()
        let unknown = await reader.readGrokSessions(home: home, now: now)
        try expect(unknown.count == 1 && unknown[0].state == .unknown && unknown[0].project == "my project", "A live TUI without an update log has unknown activity")
        let updates = sessionDir.appendingPathComponent("updates.jsonl")
        try Data("{}\n".utf8).write(to: updates)
        let working = await reader.readGrokSessions(home: home, now: now)
        try expect(working.count == 1 && working[0].state == .working, "A recent write is work in progress")
        let idle = await reader.readGrokSessions(home: home, now: now.addingTimeInterval(ActivityReader.grokStaleAfter + 1))
        try expect(idle.count == 1 && idle[0].state == .idle, "A TUI that stopped writing is idle, not working")
        try writeActive(openedAt: now.addingTimeInterval(-86_400))
        let recycled = await reader.readGrokSessions(home: home, now: now)
        try expect(recycled.isEmpty, "A pid far older than its registration has been recycled")
        let resolved = ActivityReader.grokSessionDirectory(id: sid, cwd: cwd, under: home.appendingPathComponent(".grok/sessions"))
        try expect(resolved?.standardizedFileURL.path == sessionDir.standardizedFileURL.path, "Session directory resolves through Grok's encoding")
    }

    static func inferredActivity(_ root: URL) async throws {
        let now = Date()
        let codexHome = root.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: codexHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let rollout = codexHome.appendingPathComponent("sessions/rollout-fixture.jsonl")
        try Data("{}\n".utf8).write(to: rollout)
        var db: OpaquePointer?
        guard sqlite3_open(codexHome.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else { throw Failure(description: "Codex fixture DB failed") }
        sqlite3_exec(db, "CREATE TABLE threads(rollout_path TEXT, updated_at_ms INTEGER, archived INTEGER);", nil, nil, nil)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?, 1, 0), ('/nowhere/missing.jsonl', 2, 0)", -1, &statement, nil)
        sqlite3_bind_text(statement, 1, rollout.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(statement)
        sqlite3_finalize(statement)
        sqlite3_close(db)
        let reader = ActivityReader()
        try expect(ActivityReader.newestCodexRollout(in: codexHome)?.standardizedFileURL.path == rollout.standardizedFileURL.path, "Newest existing rollout wins over a missing newer one")
        let working = await reader.readCodexSessions(codexHome: codexHome, now: now)
        try expect(working.count == 1 && working[0].state == .working && working[0].isInferred && working[0].since != nil, "A rollout written moments ago is an inferred working turn")
        let ended = await reader.readCodexSessions(codexHome: codexHome, now: now.addingTimeInterval(ActivityReader.codexStaleAfter + 1))
        try expect(ended.isEmpty, "An old rollout is a finished turn, not activity")
        let absent = await reader.readCodexSessions(codexHome: root.appendingPathComponent("absent"), now: now)
        try expect(absent.isEmpty, "No Codex state means no sessions")
        try expect(ActivityReader.codexHome(home: root, environment: ["CODEX_HOME": root.path]).standardizedFileURL.path == root.standardizedFileURL.path, "Respect CODEX_HOME for activity")

        let brain = root.appendingPathComponent("antigravity/brain")
        let logs = brain.appendingPathComponent("trajectory-1/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: logs.appendingPathComponent("transcript.jsonl"))
        let antigravity = await reader.readAntigravitySessions(root: brain, now: now)
        try expect(antigravity.count == 1 && antigravity[0].state == .working && antigravity[0].isInferred && antigravity[0].id == "antigravity-trajectory-1", "A transcript written moments ago is an inferred working turn")
        let quiet = await reader.readAntigravitySessions(root: brain, now: now.addingTimeInterval(ActivityReader.antigravityStaleAfter + 1))
        try expect(quiet.isEmpty, "A quiet transcript is not activity")
        try expect(ProviderID.codex.supportsActivity && ProviderID.antigravity.supportsActivity && !ProviderID.opencode.supportsActivity, "Activity support per provider")
    }

    static func elapsedAndCaps() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try expect(ElapsedCopy.text(since: now.addingTimeInterval(-10), now: now) == "just now", "Under 45 seconds is just now")
        try expect(ElapsedCopy.text(since: now.addingTimeInterval(-6 * 60 - 20), now: now) == "6 min", "Minutes round")
        try expect(ElapsedCopy.text(since: now.addingTimeInterval(-3600), now: now) == "1 hr", "Whole hours")
        try expect(ElapsedCopy.text(since: now.addingTimeInterval(-3900), now: now) == "1 hr 5 min", "Hours and minutes")
        try expect(ElapsedCopy.text(since: now.addingTimeInterval(60), now: now) == "just now", "A future stamp never goes negative")
        try expect(SessionListCap.count(visibleHeight: 400) == SessionListCap.minimum, "A small display still shows a few rows")
        try expect(SessionListCap.count(visibleHeight: 5000) == SessionListCap.maximum, "A huge display is capped for glanceability")
        try expect(SessionListCap.count(visibleHeight: 700) == 8, "Rows are solved from the display height")
    }

    static func releaseNotes() throws {
        let project = try String(contentsOfFile: "GaugeZ.xcodeproj/project.pbxproj", encoding: .utf8)
        let versions = Set(project.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "MARKETING_VERSION = ") else { return nil }
            return line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "; \t"))
        })
        try expect(versions.count == 1, "One marketing version across configurations")
        let current = versions.first!
        try expect(ReleaseNotes.note(for: current) != nil, "MARKETING_VERSION \(current) has a release note; add one to ReleaseNotes.swift")
        try expect(Set(ReleaseNotes.all.map(\.version)).count == ReleaseNotes.all.count, "No version is listed twice")
        try expect(ReleaseNotes.all.allSatisfy { !$0.headline.isEmpty && !$0.changes.isEmpty && $0.changes.allSatisfy { !$0.title.isEmpty } }, "Every shipped note says something")
        let notes = [ReleaseNote(version: "2.0.0", headline: "Fixture", changes: [.init("Change")])]
        try expect(ReleaseNotes.unseen(in: "2.0.0", lastSeen: nil, notes: notes)?.version == "2.0.0", "A never-seen version shows its note")
        try expect(ReleaseNotes.unseen(in: "2.0.0", lastSeen: "1.9.0", notes: notes)?.version == "2.0.0", "An update shows the new version's note")
        try expect(ReleaseNotes.unseen(in: "2.0.0", lastSeen: "2.0.0", notes: notes) == nil, "A seen version is not shown again")
        try expect(ReleaseNotes.unseen(in: "2.0.1", lastSeen: "2.0.0", notes: notes) == nil, "A version with no note shows nothing")
    }

    static func openCodeParsing(_ root: URL) throws {
        let live = Data(#"{"usage":{"rolling":{"status":"ok","percent":12.4,"resetsAt":"2026-09-06T12:31:06.611Z"},"weekly":{"status":"ok","percent":3,"resetsAt":"2026-09-07T00:00:00Z"},"monthly":{"status":"ok","percent":0,"resetsAt":"2026-10-03T13:09:45.611Z"}}}"#.utf8)
        let windows = try OpenCodeUsageParser.windows(from: live)
        try expect(windows.map(\.id) == ["rolling", "weekly", "monthly"], "OpenCode windows in headline order")
        try expect(windows[0].remainingPercent == 87.6 && windows[0].durationMinutes == 300, "Percent is already used; rolling is the 5-hour window")
        try expect(windows[0].resetsAt == OpenCodeUsageParser.date(from: "2026-09-06T12:31:06.611Z") && windows[1].resetsAt == OpenCodeUsageParser.date(from: "2026-09-07T00:00:00Z"), "Fractional and plain resets both parse")
        for json in ["{}", #"{"usage":{}}"#, #"{"usage":{"rolling":{"percent":-1}}}"#, #"{"usage":{"rolling":{"percent":"12"}}}"#] {
            try rejects({ _ = try OpenCodeUsageParser.windows(from: Data(json.utf8)) }, "Missing or invalid OpenCode data is not free quota")
        }
        let file = root.appendingPathComponent("opencode-auth.json")
        try Data(#"{"opencode-go":{"type":"api","key":"go-fixture"},"openai":{"type":"api","key":"sk-other"}}"#.utf8).write(to: file)
        try expect(OpenCodeCredentials.load(from: file)?.token == "go-fixture", "Read the Go key from an object entry")
        try Data(#"{"opencode-go":"go-plain"}"#.utf8).write(to: file)
        try expect(OpenCodeCredentials.load(from: file)?.token == "go-plain", "Read the Go key from a bare string entry")
        try Data(#"{"openai":{"type":"api","key":"sk-other"}}"#.utf8).write(to: file)
        try expect(OpenCodeCredentials.load(from: file) == nil, "Never claim another vendor's key")
        try Data(#"{"opencode-go":{"key":""}}"#.utf8).write(to: file)
        try expect(OpenCodeCredentials.load(from: file) == nil, "An empty key is not a sign-in")
        try Data(#"{"opencode-go":{"key":"bad\r\nheader"}}"#.utf8).write(to: file)
        try expect(OpenCodeCredentials.load(from: file) == nil, "Reject credential header injection")
        try expect(OpenCodeCredentials.load(from: root.appendingPathComponent("missing.json")) == nil, "No auth file means not signed in")
    }

    static func openCodeNetworking(root: URL, defaults: UserDefaults) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let policy = ProviderRetryPolicy(provider: .opencode, defaults: defaults)
        let provider = OpenCodeUsageProvider(session: session, retryPolicy: policy, loadCredentials: { .init(token: "go-fixture") })
        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, #"{"usage":{"rolling":{"percent":40},"weekly":{"percent":10}}}"#)]
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.provider == .opencode && snapshot.remainingPercent == 60 && snapshot.planName == "OpenCode Go", "OpenCode snapshot")
        let request = FixtureProtocol.requests.last!
        try expect(request.url == OpenCodeUsageParser.endpoint && request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "Bearer go-fixture", "Official Go usage route with bearer key")
        FixtureProtocol.responses = [(401, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected OpenCode 401") }
        catch OpenCodeProviderError.unauthorized { checks += 1 }
        FixtureProtocol.responses = [(403, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected OpenCode 403") }
        catch OpenCodeProviderError.noPlan { checks += 1 }
        FixtureProtocol.responses = [(429, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected OpenCode throttle") }
        catch is ProviderRetryError { checks += 1 }
        try expect(policy.deadline != nil, "OpenCode persists server backoff")
        let count = FixtureProtocol.requests.count
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected local backoff") }
        catch is ProviderRetryError { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No OpenCode request during backoff")
        policy.reset()
        let signedOut = OpenCodeUsageProvider(session: session, retryPolicy: policy, loadCredentials: { nil })
        do { _ = try await signedOut.fetchSnapshot(); throw Failure(description: "Expected not signed in") }
        catch OpenCodeProviderError.notSignedIn { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No request without a key")
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

    static func codexParsing(_ root: URL) throws {
        let free = Data(#"{"rate_limit":{"primary_window":{"limit_window_seconds":2592000,"used_percent":12.4,"reset_at":1800000000},"secondary_window":{"limit_window_seconds":604800,"used_percent":3,"reset_after_seconds":3600}},"additional_rate_limits":[]}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_799_000_000)
        let windows = try CodexWebUsage.windows(from: free, now: now)
        try expect(windows.map(\.id) == ["primary", "secondary"], "Both windows read")
        try expect(windows[0].label == "30-day limit" && windows[0].durationMinutes == 43_200, "A free plan's 30-day window is labeled from its length")
        try expect(windows[0].usedPercent == 12.4 && windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000), "Epoch reset and precise percent")
        try expect(windows[1].label == "Weekly limit" && windows[1].resetsAt == now.addingTimeInterval(3600), "reset_after_seconds is relative to now")
        for json in ["{}", #"{"rate_limit":{}}"#, #"{"rate_limit":{"primary_window":{"limit_window_seconds":300}}}"#] {
            try rejects({ _ = try CodexWebUsage.windows(from: Data(json.utf8)) }, "Missing Codex windows are not free quota")
        }
        try expect(CodexWindowLabel.label(minutes: nil, fallback: "Current limit") == "Current limit", "Omitted duration keeps the fallback label")
        func jwt(_ claims: [String: Any]) throws -> String {
            let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return "header." + payload + ".sig"
        }
        let access = try jwt(["exp": 4_102_444_800])
        let identity = try jwt(["email": "fixture@example.test", "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]])
        let auth = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": access, "account_id": "acct-fixture", "id_token": identity]])
        let credential = try CodexWebCredential.decode(auth)
        try expect(credential.accountID == "acct-fixture" && credential.email == "fixture@example.test" && credential.planType == "plus", "Identity from the CLI's id_token")
        try expect(credential.expiresAt == Date(timeIntervalSince1970: 4_102_444_800), "Expiry from the access token's exp claim")
        try rejects({ _ = try CodexWebCredential.decode(Data(#"{"OPENAI_API_KEY":"sk-fixture","tokens":null}"#.utf8)) }, "An API-key sign-in has no ChatGPT usage to read")
        try rejects({ _ = try CodexWebCredential.decode(Data(#"{"tokens":{"access_token":"bad\r\nheader","account_id":"a"}}"#.utf8)) }, "Reject credential header injection")
        try expect(try CodexWebCredential.load(url: root.appendingPathComponent("missing-auth.json")) == nil, "No auth file means the CLI never signed in")
        try expect(CodexWebCredential.authURL(home: root, environment: ["CODEX_HOME": root.path]) == root.appendingPathComponent("auth.json"), "Respect CODEX_HOME")
        let bin = root.appendingPathComponent("codex-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // The machine running this may have its own codex in a system directory, so only the
        // fixture's precedence is asserted, not the absence of every install.
        let cli = bin.appendingPathComponent("codex")
        try expect(CodexInstallation.locateExecutable(home: root, environment: ["PATH": bin.path], applicationBundles: []) == nil, "Nothing on the path yet")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try expect(CodexInstallation.locateExecutable(home: root, environment: ["PATH": bin.path], applicationBundles: [])?.path == cli.path, "A codex CLI on the user's PATH is found")
        try expect(CodexInstallation.locateExecutable(home: root, environment: ["PATH": bin.path], applicationBundles: [root.appendingPathComponent("absent")])?.path == cli.path, "A missing app bundle falls through to the CLI")
        try expect(CodexInstallation.searchDirectories(home: root, environment: ["PATH": "/a:/b:/a"]).prefix(2) == ["/a", "/b"], "PATH entries lead the search, deduplicated")
        try expect(CodexInstallation.environment(for: cli, base: ["PATH": "/usr/bin"])["PATH"]?.hasPrefix(bin.path) == true, "The launcher's own directory leads the child's PATH")
    }

    static func codexNetworking(root: URL, defaults: UserDefaults) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let policy = ProviderRetryPolicy(provider: .codex, defaults: defaults)
        let credential = CodexWebCredential(accessToken: "codex-fixture", accountID: "acct-fixture", expiresAt: .distantFuture, email: nil, planType: "plus")
        let provider = CodexUsageProvider(session: session, retryPolicy: policy, locateExecutable: { nil }, loadCredential: { credential })
        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, #"{"rate_limit":{"primary_window":{"limit_window_seconds":18000,"used_percent":40}}}"#)]
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.provider == .codex && snapshot.remainingPercent == 60 && snapshot.planName == "ChatGPT Plus", "Codex reads through the CLI sign-in when no app-server exists")
        let request = FixtureProtocol.requests.last!
        try expect(request.url == CodexWebUsage.endpoint && request.httpMethod == "GET", "Official usage route, read-only")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer codex-fixture" && request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-fixture", "Codex account headers")
        FixtureProtocol.responses = [(401, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Codex 401") }
        catch CodexProviderError.unauthorized { checks += 1 }
        FixtureProtocol.responses = [(429, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Codex throttle") }
        catch is ProviderRetryError { checks += 1 }
        try expect(policy.deadline != nil, "Codex persists server backoff")
        let count = FixtureProtocol.requests.count
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected local backoff") }
        catch is ProviderRetryError { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No Codex request during backoff")
        policy.reset()
        let missing = CodexUsageProvider(session: session, retryPolicy: policy, locateExecutable: { nil }, loadCredential: { nil })
        do { _ = try await missing.fetchSnapshot(); throw Failure(description: "Expected not installed") }
        catch CodexProviderError.notInstalled { checks += 1 }
        let expired = CodexUsageProvider(session: session, retryPolicy: policy, locateExecutable: { nil }, loadCredential: {
            CodexWebCredential(accessToken: "codex-fixture", accountID: "acct-fixture", expiresAt: .distantPast, email: nil, planType: nil)
        })
        do { _ = try await expired.fetchSnapshot(); throw Failure(description: "Expected expired sign-in") }
        catch CodexProviderError.sessionExpired { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "Expired or missing credentials never sent")
        try expect(policy.throttled(retryAfter: 5).until.timeIntervalSince(Date()) > 55, "Local throttle honors the one-minute floor")
        policy.reset()
    }

    static func grok(_ root: URL) throws {
        let modern = Data(#"{"config":{"creditUsagePercent":42.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2027-01-08T00:00:00Z"},"isUnifiedBillingUser":true,"onDemandCap":{"val":1000},"onDemandUsed":{"val":250},"monthlyLimit":{"val":100},"used":{"val":99}}}"#.utf8)
        let parsed = try GrokUsageParser.parse(modern)
        try expect(parsed.windows[0].remainingPercent == 57.5, "Grok prefers current percent over legacy cents")
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
