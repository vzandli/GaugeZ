import AppKit
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
        try await codenotchUpdates(root, defaults)
        try await portedFeatures(root, defaults)
        try profiles(root)
        try credentials()
        try keychainTransient()
        try keychainPrompt()
        try emptiedClaudeLogin(root)
        try automaticHeadline()
        try usageEvents()
        try antigravityUnifiedParser()
        try codexResetCredits()
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
        try paceAndThresholds()
        try await codexTurnsAndExtras(root)
        try kimiParsing(root)
        try await kimiNetworking(root: root, defaults: defaults)
        try commandCodeParsing(root)
        try await commandCodeNetworking(root: root, defaults: defaults)
        try ollamaParsing()
        try await ollamaNetworking(defaults: defaults)
        try devinParsing(root)
        try await devinNetworking(root: root, defaults: defaults)
        try await kiro(root, defaults)
        try minimaxParsing()
        try await minimaxNetworking(root: root, defaults: defaults)
        try await gemini(root)
        print("Passed \(checks) provider regression checks.")
    }

    // MARK: - Pace, thresholds, Codex turns and extras

    static func paceAndThresholds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let halfway = UsageWindow(id: "w", label: "Weekly limit", usedPercent: 60, resetsAt: now.addingTimeInterval(3.5 * 86_400), durationMinutes: 10_080)
        try expect(halfway.pace(now: now)?.percentagePoints == 10 && halfway.pace(now: now)?.isOver == true, "60% used halfway through is 10 points over pace")
        let slow = UsageWindow(id: "w", label: "Weekly limit", usedPercent: 20, resetsAt: now.addingTimeInterval(3.5 * 86_400), durationMinutes: 10_080)
        try expect(slow.pace(now: now)?.percentagePoints == -30, "20% used halfway through is 30 points under pace")
        let skewed = UsageWindow(id: "w", label: "5-hour limit", usedPercent: 5, resetsAt: now.addingTimeInterval(6 * 3600), durationMinutes: 300)
        try expect(skewed.pace(now: now)?.percentagePoints == 5, "A reset beyond one cycle counts as a window that just opened")
        for window in [UsageWindow(id: "w", label: "x", usedPercent: 5, resetsAt: nil, durationMinutes: 300),
                       UsageWindow(id: "w", label: "x", usedPercent: 5, resetsAt: now.addingTimeInterval(60), durationMinutes: nil),
                       UsageWindow(id: "w", label: "x", usedPercent: 5, resetsAt: now.addingTimeInterval(-60), durationMinutes: 300)] {
            try expect(window.pace(now: now) == nil, "No pace without a length and a future reset")
        }

        // Day 3 of 7 allows three sevenths of the week: 30% of the week used is 70% of that share.
        let weekly = UsageWindow(id: "seven_day", label: "Weekly limit", usedPercent: 30, resetsAt: now.addingTimeInterval(4.5 * 86_400), durationMinutes: 10_080)
        let daily = DailyPace.window(weekly: weekly, now: now)
        try expect(daily.map { abs($0.usedPercent - 70) < 0.0001 } == true && daily?.durationMinutes == nil, "Daily pace meters the cumulative daily share")
        try expect(daily?.resetsAt == now.addingTimeInterval(0.5 * 86_400), "The next share arrives when the day counted from the weekly reset ends")
        let claude = UsageSnapshot(provider: .claude, accountID: nil, planName: nil, windows: [weekly], observedAt: now, source: "fixture", health: .live)
        let paced = DailyPace.apply(to: claude, now: now)
        try expect(paced.windows.map(\.id) == [DailyPace.windowID, "seven_day"] && paced.headlineWindow?.id == DailyPace.windowID, "Daily pace leads Claude and is the headline")
        try expect(DailyPace.apply(to: paced, now: now).windows.count == 2, "Applying twice adds one window")
        let codex = UsageSnapshot(provider: .codex, accountID: nil, planName: nil, windows: [weekly], observedAt: now, source: "fixture", health: .live)
        try expect(DailyPace.apply(to: codex, now: now) == codex, "Only Claude is paced")

        func snapshot(_ used: Double) -> UsageSnapshot {
            UsageSnapshot(provider: .cursor, accountID: nil, planName: nil,
                          windows: [UsageWindow(id: "w", label: "Plan", usedPercent: used, resetsAt: nil, durationMinutes: nil)],
                          observedAt: now, source: "fixture", health: .live)
        }
        var notifier = ThresholdNotifier()
        notifier.warnRemaining = 40
        notifier.criticalRemaining = 10
        try expect(notifier.observe(snapshot(50)).isEmpty, "Above the warning level is quiet")
        try expect(notifier.observe(snapshot(65)).map(\.threshold) == [80], "A custom warning level fires at 40% left")
        try expect(notifier.observe(snapshot(70)).isEmpty, "A crossing alerts once")
        try expect(notifier.observe(snapshot(92)).map(\.threshold) == [100], "A custom critical level fires at 10% left")
        try expect(notifier.observe(snapshot(10)).isEmpty && notifier.observe(snapshot(95)).map(\.threshold) == [80, 100], "Recovery re-arms both levels")
        notifier.criticalRemaining = 60
        try expect(notifier.observe(snapshot(10)).isEmpty && notifier.observe(snapshot(65)).map(\.threshold) == [80, 100], "The critical level never sits above the warning")
    }

    static func codexTurnsAndExtras(_ root: URL) async throws {
        func event(_ type: String) -> String { #"{"type":"event_msg","payload":{"type":"\#(type)"}}"# }
        let filler = #"{"type":"response_item","payload":{"type":"message","text":"\#(String(repeating: "x", count: 900))"}}"#
        let rollout = root.appendingPathComponent("rollout-turns.jsonl")
        try Data(([event("task_started")] + Array(repeating: filler, count: 20)).joined(separator: "\n").utf8).write(to: rollout)
        try expect(CodexRollout.latestTurn(in: rollout) == .started, "A started turn behind streamed output is found")
        try Data(([event("task_started")] + Array(repeating: filler, count: 600) + [event("task_complete"), #"{"type":"event_msg","payload":{"type":"item_completed"}}"#]).joined(separator: "\n").utf8).write(to: rollout)
        try expect(CodexRollout.latestTurn(in: rollout) == .completed, "The newest lifecycle event wins, across read windows, and item_completed is not one")
        try Data(([event("task_complete"), event("task_started"), event("turn_aborted")]).joined(separator: "\n").utf8).write(to: rollout)
        try expect(CodexRollout.latestTurn(in: rollout) == .aborted, "An aborted turn is not a completion")
        try Data(Array(repeating: filler, count: 5).joined(separator: "\n").utf8).write(to: rollout)
        try expect(CodexRollout.latestTurn(in: rollout) == nil && CodexRollout.latestTurn(in: root.appendingPathComponent("absent.jsonl")) == nil, "No lifecycle event is no answer")

        let usage = Data(#"""
        {"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":60},
                       "secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_after_seconds":600}},
         "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":18000}}},
                                   {"limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":3,"limit_window_seconds":18000}}},
                                   {"limit_name":"Other","rate_limit":{"primary_window":{"used_percent":99}}}],
         "code_review_rate_limit":{"primary_window":{"used_percent":"bad"},"secondary_window":{"used_percent":7,"limit_window_seconds":604800}}}
        """#.utf8)
        let windows = try CodexWebUsage.windows(from: usage)
        try expect(windows.map(\.id) == ["primary", "secondary", "spark", "code-review-secondary"], "Spark once, code review's good window kept, unknown extras dropped")
        try expect(windows.map(\.isExtra) == [false, false, true, true] && windows[2].label.hasPrefix("Spark"), "Extras are marked and named by group")
        try expect(UsageSnapshot.automaticHeadline(in: windows)?.id == "secondary", "An exhausted extra never becomes the headline")
        var watcher = UsageEventWatcher()
        func codex(_ sparkUsed: Double) -> UsageSnapshot {
            UsageSnapshot(provider: .codex, accountID: nil, planName: nil, windows: [
                UsageWindow(id: "primary", label: "5-hour limit", usedPercent: 10, resetsAt: nil, durationMinutes: 300),
                UsageWindow(id: "spark", label: "Spark", usedPercent: sparkUsed, resetsAt: nil, durationMinutes: 300, isExtra: true)
            ], observedAt: .now, source: "fixture", health: .live)
        }
        _ = watcher.observe(codex(50))
        try expect(watcher.observe(codex(100)).isEmpty, "An extra window reaching zero is not a limit event")
        let legacy = try JSONDecoder().decode(UsageWindow.self, from: Data(#"{"id":"w","label":"x","usedPercent":5}"#.utf8))
        try expect(!legacy.isExtra && legacy.resetsAt == nil, "Caches written before extras existed still load")

        let profile = Data(#"{"stats":{"daily_usage_buckets":[{"start_date":"2026-09-18","tokens":1200},{"start_date":"2026-09-19T00:00:00Z","tokens":2500000},{"start_date":"bad","tokens":-1}]}}"#.utf8)
        let buckets = CodexWebUsage.dailyTokens(from: profile) ?? []
        try expect(buckets.map(\.tokens) == [1200, 2_500_000] && CodexWebUsage.dailyTokens(from: Data("{}".utf8)) == nil, "Daily buckets parse; a body without them draws no chart")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let recent = DailyTokenBucket.recent(buckets, days: 3, now: Date(timeIntervalSince1970: 1_789_819_200), calendar: utc)
        try expect(recent.map(\.day) == ["2026-09-17", "2026-09-18", "2026-09-19"] && recent.map(\.tokens) == [0, 1200, 2_500_000], "Quiet days are filled in and today is last")
        try expect(DailyTokenBucket.compact(2_500_000) == "2.5M" && DailyTokenBucket.compact(1200) == "1k" && DailyTokenBucket.compact(12) == "12", "Compact token counts")

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        try expect(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 7, windows: [(7, 0, screen)]), "A window spanning the display is full screen")
        try expect(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 7, windows: [(7, 0, CGRect(x: 0, y: 38, width: 1512, height: 944))], safeAreaTopInset: 38), "Below the camera housing still counts")
        try expect(!FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 7, windows: [(7, 0, CGRect(x: 0, y: 38, width: 1512, height: 860)), (8, 0, screen), (7, 25, screen)]), "A maximized window, another app, or an overlay layer does not")

        let track = BorderTrack(frame: CGRect(x: 0, y: 100, width: 1000, height: 800))
        try expect(track.perimeter == 3600 && track.place(at: 1200) == (.right, 200) && track.place(at: -100) == (.left, 700), "The border runs clockwise from the top-left and wraps")
        try expect(track.along(.top, of: 1050) == 1050 && track.along(.right, of: 950) == -50, "A rail reaching past a corner is laid along both edges' lines")
        try expect(track.edges(spannedBy: 1000, length: 300) == [.top, .right] && track.edges(spannedBy: 500, length: 300) == [.top], "A rail at a corner spans both edges")
        let nearCorner = CGPoint(x: 950, y: 850)
        try expect(track.reading(of: nearCorner, nearest: .top) == .corner(.topRight) && track.place(of: nearCorner, by: .corner(.topRight)) == 1000, "Near a corner the pointer is read from both edges at once")
        try expect(track.nearestEdge(to: CGPoint(x: 970, y: 850), current: .top) == .top && track.nearestEdge(to: CGPoint(x: 990, y: 500), current: .top) == .right, "Switching edges takes a clear margin")
        let landing = RailLanding(track: track, railLength: 400, horizontalPanelWidth: 420)
        try expect(landing.savedPosition(along: 400, on: .right) == 0.5 && landing.savedPosition(along: 212, on: .right) == 1 && landing.savedPosition(along: 0, on: .top) == 0, "Saved positions run bottom to top and left to right, clamped")
        for edge in [EdgeSide.top, .right, .bottom, .left] {
            try expect(abs(landing.savedPosition(along: landing.position(saved: 0.3, on: edge) - track.start(of: edge), on: edge) - 0.3) < 1e-9, "Saved position round-trips on \(edge)")
        }
        let renamed = ProviderID(rawValue: "claude-nickname-fixture")!
        ProviderNicknames.set("  Work  ", for: renamed)
        try expect(renamed.displayName == "Work" && renamed.defaultName == "Claude (nickname-fixture)", "A nickname is trimmed and names the account everywhere")
        ProviderNicknames.set(renamed.defaultName, for: renamed)
        try expect(ProviderNicknames.name(for: renamed) == nil && renamed.displayName == "Claude (nickname-fixture)", "Renaming back to its own name clears the nickname")
        let settled = landing.landing(for: 1010)
        try expect(settled.edge == .right && settled.saved == 1, "Let go just round a corner, the rail slides fully onto that edge")
    }

    // MARK: - Kimi

    static func kimiParsing(_ root: URL) throws {
        let live = Data(#"""
        {"user":{"userId":"fixture-user","membership":{"level":"LEVEL_ADVANCED"}},
         "usage":{"limit":"100","used":"2","remaining":"98","resetTime":"2026-09-15T19:39:34.389610Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"100","used":"8","remaining":"92","resetTime":"2026-09-11T16:39:34.389610Z"}}]}
        """#.utf8)
        let read = try KimiUsageParser.read(from: live)
        try expect(read.windows.map(\.id) == ["weekly", "rolling"], "Kimi summary is the weekly window, limits[] names its own")
        try expect(read.windows[0].usedPercent == 2 && read.windows[0].durationMinutes == 10_080, "Weekly counts become a percent used")
        try expect(read.windows[1].usedPercent == 8 && read.windows[1].durationMinutes == 300, "A 300-minute window is the 5-hour one")
        try expect(read.windows[1].resetsAt == KimiUsageParser.date(from: "2026-09-11T16:39:34.389610Z"), "Fractional resets parse")
        try expect(read.plan == "Advanced", "LEVEL_ADVANCED names the tier")

        let hourly = Data(#"{"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"50","used":"50"}},{"window":{"duration":1,"timeUnit":"TIME_UNIT_WEEK"},"detail":{"limit":"200","used":"20"}}]}"#.utf8)
        let both = try KimiUsageParser.read(from: hourly)
        try expect(both.windows.map(\.id) == ["rolling", "weekly"], "Hour and week units are recognized")
        try expect(both.windows[0].isExhausted && both.windows[1].usedPercent == 10, "Used over limit is the percent used")
        try expect(both.plan == nil, "No membership means no plan name")

        let duplicated = Data(#"{"usage":{"limit":"100","used":"5"},"limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_WEEK"},"detail":{"limit":"100","used":"90"}}]}"#.utf8)
        try expect(try KimiUsageParser.read(from: duplicated).windows.map(\.id) == ["weekly"], "The weekly window is not listed twice")

        let unknown = Data(#"{"usage":{"limit":"100","used":"1"},"limits":[{"window":{"duration":17,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"9","used":"1"}}]}"#.utf8)
        try expect(try KimiUsageParser.read(from: unknown).windows.map(\.id) == ["weekly"], "An unnamed window is dropped, not mislabelled")

        for json in ["{}", "[]", #"{"usage":{}}"#, #"{"usage":{"used":"2"}}"#, #"{"usage":{"limit":"100"}}"#,
                     #"{"usage":{"limit":"100","used":"none"}}"#, #"{"limits":[]}"#] {
            try rejects({ _ = try KimiUsageParser.read(from: Data(json.utf8)) }, "Missing or invalid Kimi data is not free quota: \(json)")
        }

        // Credentials
        let home = root.appendingPathComponent("kimi-home")
        let credentials = home.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        let file = credentials.appendingPathComponent("kimi-code.json")
        try expect(KimiCredentialReader.authURL(home: home, environment: [:]).path == home.appendingPathComponent(".kimi-code/credentials/kimi-code.json").path, "Default path is ~/.kimi-code")
        try expect(KimiCredentialReader.authURL(home: home, environment: ["KIMI_CODE_HOME": home.path]) == file, "KIMI_CODE_HOME moves the data root")
        try expect(KimiCredentialReader.authURL(home: home, environment: ["KIMI_CODE_HOME": ""]).path.hasSuffix(".kimi-code/credentials/kimi-code.json"), "An empty override is ignored")

        try Data(#"{"access_token":"kimi-fixture","expires_at":4102444800}"#.utf8).write(to: file)
        let loaded = try KimiCredentialReader.load(from: file)
        try expect(loaded.accessToken == "kimi-fixture" && loaded.expiresAt > .now, "Read the token and its expiry")
        try Data(#"{"access_token":"kimi-fixture"}"#.utf8).write(to: file)
        try rejects({ _ = try KimiCredentialReader.load(from: file) }, "A session with no expiry is not trusted")
        try Data(#"{"access_token":"bad\r\nheader","expires_at":4102444800}"#.utf8).write(to: file)
        try rejects({ _ = try KimiCredentialReader.load(from: file) }, "Reject Kimi credential header injection")
        try Data(#"{"access_token":"","expires_at":4102444800}"#.utf8).write(to: file)
        try rejects({ _ = try KimiCredentialReader.load(from: file) }, "An empty Kimi token is not a sign-in")
        try rejects({ _ = try KimiCredentialReader.load(from: root.appendingPathComponent("no-kimi.json")) }, "No Kimi auth file means not signed in")
    }

    static func kimiNetworking(root: URL, defaults: UserDefaults) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let policy = ProviderRetryPolicy(provider: .kimi, defaults: defaults)
        policy.reset()
        let valid = KimiCredential(accessToken: "kimi-fixture", expiresAt: .distantFuture)
        let provider = KimiUsageProvider(session: session, retryPolicy: policy, loadCredential: { valid })

        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, #"{"user":{"membership":{"level":"LEVEL_ADVANCED"}},"usage":{"limit":"100","used":"25"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"60"}}]}"#)]
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.provider == .kimi && snapshot.planName == "Kimi Code Advanced", "Kimi snapshot names the tier")
        try expect(snapshot.headlineWindow?.id == "rolling" && snapshot.remainingPercent == 40, "The 5-hour window leads")
        try expect(snapshot.accountID == nil, "The Kimi token carries no address")
        let request = FixtureProtocol.requests.last!
        try expect(request.url == KimiUsageParser.endpoint && request.httpMethod == "GET"
                   && request.value(forHTTPHeaderField: "Authorization") == "Bearer kimi-fixture", "Official usages route with bearer token")

        FixtureProtocol.responses = [(404, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Kimi 404") }
        catch KimiProviderError.noPlan { checks += 1 }
        try expect(KimiProviderError.noPlan.providerHealth == .unavailable(KimiProviderError.noPlan.errorDescription!), "No Kimi Code plan is unavailable, not signed out")

        FixtureProtocol.responses = [(401, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Kimi 401") }
        catch KimiProviderError.unauthorized { checks += 1 }

        FixtureProtocol.responses = [(429, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Kimi throttle") }
        catch is ProviderRetryError { checks += 1 }
        try expect(policy.deadline != nil, "Kimi persists server backoff")
        let count = FixtureProtocol.requests.count
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected local backoff") }
        catch is ProviderRetryError { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No Kimi request during backoff")
        policy.reset()

        let stale = KimiUsageProvider(session: session, retryPolicy: policy,
                                      loadCredential: { KimiCredential(accessToken: "kimi-fixture", expiresAt: .distantPast) })
        do { _ = try await stale.fetchSnapshot(); throw Failure(description: "Expected expired Kimi session") }
        catch KimiProviderError.expired { checks += 1 }
        let expiredHealth = KimiProviderError.expired.providerHealth
        try expect(expiredHealth == .signedOut(KimiProviderError.expired.errorDescription!), "An expired Kimi token reads as signed out")
        try expect(KimiProviderError.expired.errorDescription?.contains("kimi") == true, "The expired message names the CLI to run")

        let missing = KimiUsageProvider(session: session, retryPolicy: policy, loadCredential: { throw KimiProviderError.notSignedIn })
        do { _ = try await missing.fetchSnapshot(); throw Failure(description: "Expected no Kimi sign-in") }
        catch KimiProviderError.notSignedIn { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No Kimi request without a usable token")
        _ = root
    }

    // MARK: - Command Code

    static func commandCodeParsing(_ root: URL) throws {
        let summary = Data(#"{"totalCost":3.5,"totalCount":42}"#.utf8)
        let credits = Data(#"{"credits":{"monthlyCredits":16.5},"windowLimits":{"fiveHour":{"used":2,"cap":8,"resetAt":1789000000},"weekly":{"used":0,"cap":40,"resetAt":0}}}"#.utf8)
        let subscription = Data(#"{"data":{"planId":"goat_monthly","currentPeriodStart":"2026-09-01T00:00:00Z","currentPeriodEnd":"2026-10-01T00:00:00Z"}}"#.utf8)
        let read = try CommandCodeUsageParser.read(summary: summary, credits: credits, subscription: subscription)
        try expect(read.windows.map(\.id) == ["monthly", "fiveHour", "weekly"], "Command Code windows in headline order")
        try expect(read.windows[0].usedPercent == 17.5, "Monthly is spend over spend plus remaining credits")
        try expect(read.windows[0].durationMinutes == 43_200 && read.windows[0].resetsAt == CommandCodeUsageParser.date("2026-10-01T00:00:00Z"), "Monthly resets at the period end")
        try expect(read.windows[1].usedPercent == 25 && read.windows[1].durationMinutes == 300, "Capped five-hour window becomes a percent")
        try expect(read.windows[2].usedPercent == 0 && read.windows[2].resetsAt == nil, "A resetAt of 0 is absence, not 1970")
        try expect(read.plan == "GOAT" && read.balance == 16.5, "Plan id and remaining money are read")

        let bare = Data(#"{"planId":"team-goat-annual","currentPeriodEnd":1789000000000}"#.utf8)
        let unwrapped = try CommandCodeUsageParser.read(summary: summary, credits: credits, subscription: bare)
        try expect(unwrapped.plan == "GOAT" && unwrapped.windows[0].resetsAt == Date(timeIntervalSince1970: 1_789_000_000), "Unwrapped subscription and millisecond resets both parse")
        try expect(CommandCodeUsageParser.planName("starter") == "starter" && CommandCodeUsageParser.planName("") == nil, "An unknown plan keeps its own name")

        // Money with no allowance behind it is a balance, not a ring; windows decide the error.
        let uncapped = Data(#"{"credits":{"monthlyCredits":0},"windowLimits":{"fiveHour":{"used":1,"cap":4}}}"#.utf8)
        let windowsOnly = try CommandCodeUsageParser.read(summary: Data(#"{"totalCost":0}"#.utf8), credits: uncapped, subscription: Data("{}".utf8))
        try expect(windowsOnly.windows.map(\.id) == ["fiveHour"], "No monthly pot still leaves the metered windows")
        try rejects({ _ = try CommandCodeUsageParser.read(summary: Data(#"{"totalCost":0}"#.utf8), credits: Data(#"{"credits":{}}"#.utf8), subscription: Data("{}".utf8)) },
                    "Nothing metered at all is not zero usage")
        try rejects({ _ = try CommandCodeUsageParser.read(summary: Data("[]".utf8), credits: credits, subscription: Data("{}".utf8)) }, "A non-object summary is malformed")
        try rejects({ _ = try CommandCodeUsageParser.read(summary: summary, credits: Data("nope".utf8), subscription: Data("{}".utf8)) }, "Unreadable credits are malformed")
        let noUsed = Data(#"{"credits":{},"windowLimits":{"weekly":{"cap":40}}}"#.utf8)
        try rejects({ _ = try CommandCodeUsageParser.read(summary: Data(#"{"totalCost":0}"#.utf8), credits: noUsed, subscription: Data("{}".utf8)) },
                    "A capped window with no used figure is dropped, never zero")

        try expect(CommandCodeUsageParser.orgID(whoami: Data(#"{"org":{"id":"org-fixture"}}"#.utf8)) == "org-fixture", "whoami names the org")
        try expect(CommandCodeUsageParser.orgID(whoami: Data(#"{"org":{"id":" "}}"#.utf8)) == nil, "A blank org id is absent")

        let file = root.appendingPathComponent("commandcode-auth.json")
        try Data(#"{"apiKey":"cc-fixture","userName":"Fixture User"}"#.utf8).write(to: file)
        let credential = try CommandCodeCredentialReader.load(from: file, environment: [:])
        try expect(credential.apiKey == "cc-fixture" && credential.userName == "Fixture User", "Read the Command Code key and user")
        try expect(try CommandCodeCredentialReader.load(from: file, environment: ["COMMAND_CODE_API_KEY": "env-key"]).apiKey == "env-key", "The environment key wins")
        try Data(#"{"apiKey":"bad\nheader"}"#.utf8).write(to: file)
        try rejects({ _ = try CommandCodeCredentialReader.load(from: file, environment: [:]) }, "Reject Command Code header injection")
        try rejects({ _ = try CommandCodeCredentialReader.load(from: root.appendingPathComponent("no-cc.json"), environment: [:]) }, "No Command Code auth file means not signed in")
    }

    static func commandCodeNetworking(root: URL, defaults: UserDefaults) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let policy = ProviderRetryPolicy(provider: .commandcode, defaults: defaults)
        policy.reset()
        let provider = CommandCodeUsageProvider(session: session, retryPolicy: policy,
                                                loadCredentials: { CommandCodeCredential(apiKey: "cc-fixture", userName: "Fixture User") })
        // Credits and subscriptions are fetched concurrently, so one body answers both: each
        // parser reads only its own keys.
        let billing = #"{"credits":{"monthlyCredits":30},"windowLimits":{"weekly":{"used":5,"cap":50}},"data":{"planId":"goat_monthly","currentPeriodStart":"2026-09-01T00:00:00Z","currentPeriodEnd":"2026-10-01T00:00:00Z"}}"#

        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, #"{"org":{"id":"org-fixture"}}"#), (200, billing), (200, billing), (200, #"{"totalCost":10}"#)]
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.provider == .commandcode && snapshot.planName == "Command Code GOAT" && snapshot.accountID == "Fixture User", "Command Code snapshot")
        try expect(snapshot.headlineWindow?.id == "monthly" && snapshot.remainingPercent == 75, "Monthly leads: 10 spent of a 40 pot")
        try expect(snapshot.costInfo?.prepaidBalance == 30, "Remaining credits ride along as money")
        try expect(FixtureProtocol.requests.count == 4, "whoami, credits, subscriptions, summary")
        try expect(FixtureProtocol.requests[0].url == CommandCodeUsageParser.whoami, "whoami is asked first")
        try expect(FixtureProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer cc-fixture" }, "Every call carries the borrowed key")
        let summaryURL = FixtureProtocol.requests[3].url?.absoluteString ?? ""
        try expect(summaryURL.hasPrefix(CommandCodeUsageParser.summary.absoluteString) && summaryURL.contains("orgId=org-fixture") && summaryURL.contains("since=2026-09-01"),
                   "Spend is counted from the period start, scoped to the org")

        FixtureProtocol.responses = [(403, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Command Code 403") }
        catch CommandCodeProviderError.unauthorized { checks += 1 }

        FixtureProtocol.responses = [(429, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Command Code throttle") }
        catch is ProviderRetryError { checks += 1 }
        try expect(policy.deadline != nil, "Command Code persists server backoff")
        let count = FixtureProtocol.requests.count
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected local backoff") }
        catch is ProviderRetryError { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No Command Code request during backoff")
        policy.reset()

        let signedOut = CommandCodeUsageProvider(session: session, retryPolicy: policy, loadCredentials: { throw CommandCodeProviderError.notSignedIn })
        do { _ = try await signedOut.fetchSnapshot(); throw Failure(description: "Expected no Command Code sign-in") }
        catch CommandCodeProviderError.notSignedIn { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No Command Code request without a key")
        _ = root
    }

    // MARK: - Ollama

    static func ollamaParsing() throws {
        let modern = Data(#"{"activity":{"cost":"0.00000","period":{"type":"last_4_weeks"}},"limits":{"monthly":{"usage":0.152,"models":[{"name":"glm-5.3","request_count":468}]}}}"#.utf8)
        let windows = try OllamaUsageParser.windows(from: modern)
        try expect(windows.map(\.id) == ["monthly"], "Per-model request counts are not windows")
        try expect(abs(windows[0].usedPercent - 15.2) < 0.0001 && windows[0].durationMinutes == 43_200, "usage is a fraction of the monthly allowance")
        try expect(windows[0].resetsAt == nil, "Ollama exposes no billing reset, so none is shown")

        let legacy = Data(#"{"limits":{"session":{"usage":0,"models":[]},"weekly":{"usage":0.41}}}"#.utf8)
        let legacyWindows = try OllamaUsageParser.windows(from: legacy)
        try expect(legacyWindows.map(\.id) == ["session", "weekly"], "Legacy plans report session and weekly windows")
        try expect(legacyWindows[0].usedPercent == 0 && legacyWindows[0].remainingPercent == 100, "0% used is a reading, not a missing window")
        try expect(legacyWindows[0].durationMinutes == nil, "A session has no stated length")
        try expect(abs(legacyWindows[1].usedPercent - 41) < 0.0001, "Weekly fraction becomes a percent")

        let overflow = Data(#"{"limits":{"monthly":{"usage":1.4}}}"#.utf8)
        try expect(try OllamaUsageParser.windows(from: overflow)[0].usedPercent == 100, "Usage past the allowance clamps to full")

        for json in ["{}", "[]", #"{"limits":{}}"#, #"{"limits":{"monthly":{}}}"#, #"{"limits":{"monthly":{"usage":"0.5"}}}"#,
                     #"{"limits":{"monthly":{"usage":-1}}}"#] {
            try rejects({ _ = try OllamaUsageParser.windows(from: Data(json.utf8)) }, "Missing or invalid Ollama data is not free quota: \(json)")
        }
    }

    static func ollamaNetworking(defaults: UserDefaults) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let policy = ProviderRetryPolicy(provider: .ollama, defaults: defaults)
        policy.reset()
        let provider = OllamaUsageProvider(session: session, retryPolicy: policy, loadKey: { "ollama-fixture" })

        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, #"{"limits":{"monthly":{"usage":0.25}}}"#)]
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.provider == .ollama && snapshot.planName == "Ollama Cloud" && snapshot.remainingPercent == 75, "Ollama snapshot")
        let request = FixtureProtocol.requests.last!
        try expect(request.url == OllamaUsageParser.endpoint && request.httpMethod == "GET"
                   && request.value(forHTTPHeaderField: "Authorization") == "Bearer ollama-fixture", "Official usage route with the owned key")

        FixtureProtocol.responses = [(401, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Ollama 401") }
        catch OllamaProviderError.unauthorized { checks += 1 }

        FixtureProtocol.responses = [(429, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Ollama throttle") }
        catch is ProviderRetryError { checks += 1 }
        try expect(policy.deadline != nil, "Ollama persists server backoff")
        policy.reset()

        let count = FixtureProtocol.requests.count
        let keyless = OllamaUsageProvider(session: session, retryPolicy: policy, loadKey: { nil })
        do { _ = try await keyless.fetchSnapshot(); throw Failure(description: "Expected missing Ollama key") }
        catch OllamaProviderError.noKey { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No Ollama request without a key")
        try expect(OllamaProviderError.noKey.providerHealth == .signedOut(OllamaProviderError.noKey.errorDescription!), "A missing key reads as signed out")
    }

// Splice into Tests/ProviderRegressionTests.swift (inside the struct), and add to main():
//     try devinParsing(root)
//     try await devinNetworking(root: root, defaults: defaults)
//     try await kiro(root, defaults)

    static func devinParsing(_ root: URL) throws {
        // Protobuf JSON: 64-bit fields as strings, percentages are *remaining*.
        let live = Data(#"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":"62.5","dailyQuotaResetAtUnix":"1800000000","weeklyQuotaRemainingPercent":30,"weeklyQuotaResetAtUnix":1800500000,"overageBalanceMicros":"1500000"}}}"#.utf8)
        let windows = try DevinUsageParser.windows(from: live)
        try expect(windows.map(\.id) == ["daily", "weekly"], "Devin reports the daily and weekly quotas in that order")
        try expect(windows[0].usedPercent == 37.5 && windows[0].durationMinutes == 1440, "Devin percentages are remaining allowance, not usage")
        try expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000), "String-encoded reset timestamps parse")
        try expect(windows[1].usedPercent == 70 && windows[1].durationMinutes == 10080, "Numeric percentages parse too")
        try expect(windows.count == 2, "An overage balance has no ceiling, so it is not a window")

        // The service drops the percent at 0; the reset is what says the quota is still metered.
        let exhausted = Data(#"{"userStatus":{"planStatus":{"dailyQuotaResetAtUnix":"1800000000"}}}"#.utf8)
        try expect(try DevinUsageParser.windows(from: exhausted).map(\.usedPercent) == [100], "A missing percent beside a reset is fully used")
        let hidden = Data(#"{"userStatus":{"planStatus":{"hideDailyQuota":true,"dailyQuotaRemainingPercent":50,"weeklyQuotaRemainingPercent":10}}}"#.utf8)
        try expect(try DevinUsageParser.windows(from: hidden).map(\.id) == ["weekly"], "A hidden quota is not drawn")
        let boolean = Data(#"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":true,"dailyQuotaResetAtUnix":true}}}"#.utf8)
        try rejects({ _ = try DevinUsageParser.windows(from: boolean) }, "A JSON true is not the number 1")
        for json in ["{}", #"{"userStatus":{}}"#, #"{"userStatus":{"planStatus":{}}}"#,
                     #"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":-5}}}"#,
                     #"{"userStatus":{"planStatus":{"weeklyQuotaRemainingPercent":140}}}"#] {
            try rejects({ _ = try DevinUsageParser.windows(from: Data(json.utf8)) }, "Missing or impossible Devin data is not free quota")
        }

        // Credentials: Desktop store first, CLI file only when it has nothing to borrow.
        let store = root.appendingPathComponent("devin-state.vscdb")
        try makeItemTable(at: store, key: "windsurfAuthStatus",
                          value: #"{"apiKey":"devin-fixture","email":"fixture@example.invalid"}"#)
        let cli = root.appendingPathComponent("devin-credentials.toml")
        try Data("windsurf_api_key = \"cli-fixture\"\n".utf8).write(to: cli)
        let desktop = try DevinLocalSession.load(stateDatabase: store, cliCredentials: cli)
        try expect(desktop.apiKey == "devin-fixture" && desktop.email == "fixture@example.invalid", "Devin Desktop's sign-in wins")
        let missing = root.appendingPathComponent("devin-absent.vscdb")
        let fallback = try DevinLocalSession.load(stateDatabase: missing, cliCredentials: cli)
        try expect(fallback.apiKey == "cli-fixture" && fallback.email == nil, "The CLI file is the fallback")
        try makeItemTable(at: store, key: "windsurfAuthStatus", value: #"{"apiKey":"bad\r\nheader"}"#)
        try expect(DevinLocalSession.loadDesktop(from: store) == nil, "Reject credential header injection")
        try makeItemTable(at: store, key: "windsurfAuthStatus", value: #"{"apiKey":""}"#)
        try expect(DevinLocalSession.loadDesktop(from: store) == nil, "An empty key is not a sign-in")
        try rejects({ _ = try DevinLocalSession.load(stateDatabase: missing, cliCredentials: root.appendingPathComponent("nope.toml")) },
                    "No Devin source at all is not signed in")
    }

    /// A one-key `ItemTable`, the VS Code store shape Devin Desktop uses.
    static func makeItemTable(at url: URL, key: String, value: String) throws {
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw Failure(description: "Could not create \(url.path)") }
        defer { sqlite3_close(db) }
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        let sql = "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value BLOB);"
            + "DELETE FROM ItemTable;INSERT INTO ItemTable VALUES ('\(key)', '\(escaped)');"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(description: "Could not seed \(url.path)") }
    }

    static func devinNetworking(root: URL, defaults: UserDefaults) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let policy = ProviderRetryPolicy(provider: .devin, defaults: defaults)
        let credential = DevinLocalSession(apiKey: "devin-fixture", email: "fixture@example.invalid", source: "fixture")
        let provider = DevinUsageProvider(session: session, retryPolicy: policy, loadCredentials: { credential })

        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, #"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":80,"weeklyQuotaRemainingPercent":45}}}"#)]
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.provider == .devin && snapshot.accountID == "fixture@example.invalid", "Devin snapshot carries the borrowed account")
        try expect(snapshot.windows.map(\.remainingPercent) == [80, 45], "Devin snapshot keeps both quotas")
        let request = FixtureProtocol.requests.last!
        try expect(request.url == DevinUsageParser.endpoint && request.httpMethod == "POST", "GetUserStatus over Connect")
        try expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1", "Connect handshake header is sent")
        try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "Devin carries its key in the body, never a header")

        FixtureProtocol.responses = [(401, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Devin 401") }
        catch DevinProviderError.unauthorized { checks += 1 }
        FixtureProtocol.responses = [(403, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Devin 403") }
        catch DevinProviderError.accessDenied { checks += 1 }
        FixtureProtocol.responses = [(503, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Devin 503") }
        catch DevinProviderError.server(503) { checks += 1 }
        FixtureProtocol.responses = [(429, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected Devin throttle") }
        catch is ProviderRetryError { checks += 1 }
        try expect(policy.deadline != nil, "Devin persists server backoff")
        let count = FixtureProtocol.requests.count
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected local backoff") }
        catch is ProviderRetryError { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No Devin request during backoff")
        policy.reset()

        let signedOut = DevinUsageProvider(session: session, retryPolicy: policy,
                                           loadCredentials: { throw DevinProviderError.notSignedIn })
        do { _ = try await signedOut.fetchSnapshot(); throw Failure(description: "Expected Devin not signed in") }
        catch DevinProviderError.notSignedIn { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No request without a borrowed key")
        try expect(DevinProviderError.notSignedIn.providerHealth == .signedOut(DevinProviderError.notSignedIn.errorDescription!), "A missing Devin sign-in reads as signed out")
    }

    static func kiro(_ root: URL, _ defaults: UserDefaults) async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 UTC
        let card = """
        \u{1B}[1m╭────────────────────────────────────────────╮\u{1B}[0m
        │ Estimated Usage | Plan: KIRO PRO | 3 usage breakdowns │
        │ \u{1B}[32m████████████\u{1B}[0m 42% (210.0 of 500 covered in plan) │
        │ Credits reset on 2027-02-01                │
        ╰────────────────────────────────────────────╯
        """
        let reading = try KiroUsageParser.reading(from: card, now: now)
        try expect(reading.credits.id == "credits" && reading.credits.usedPercent == 42, "The bar's percent is the credit reading")
        try expect(reading.credits.durationMinutes == 43200, "Kiro credits are a monthly pool")
        try expect(reading.plan == "Kiro Pro", "A shouted plan name is title-cased")
        try expect(KiroUsageParser.stripANSI(card).contains("\u{1B}") == false, "ANSI escapes are stripped before parsing")

        // No bar: the "(X of Y covered in plan)" pair is used of total, not remaining.
        let pairOnly = "Estimated Usage | Plan: KIRO FREE\n(25 of 100 covered in plan)\nresets on 2/1\n"
        let fromPair = try KiroUsageParser.reading(from: pairOnly, now: now)
        try expect(fromPair.credits.usedPercent == 25 && fromPair.plan == "Kiro Free", "The credit pair is a fallback reading")
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.locale = Locale(identifier: "en_US_POSIX")
        try expect(gregorian.component(.year, from: fromPair.credits.resetsAt!) == 2027
                   && gregorian.component(.month, from: fromPair.credits.resetsAt!) == 2, "An MM/DD reset still ahead stays in this year")
        let pastReset = try KiroUsageParser.reading(from: "\u{1B}[0m███ 10% resets on 1/2", now: now)
        try expect(gregorian.component(.year, from: pastReset.credits.resetsAt ?? .distantPast) == 2028, "An MM/DD reset already past rolls into next year")

        // Nothing metered is never a 0% ring.
        try rejects({ _ = try KiroUsageParser.reading(from: "Estimated Usage | Plan: KIRO FREE\n") }, "A plan name with no meter is not 0% used")
        try rejects({ _ = try KiroUsageParser.reading(from: "") }, "Empty CLI output is not a reading")
        for text in ["You are not logged in. Run kiro-cli login.", "\u{1B}[31mOAuth error\u{1B}[0m: token expired",
                     "login required", "failed to initialize auth portal"] {
            try expect(KiroUsageParser.mentionsSignedOut(text), "kiro-cli says signed out in its own words: \(text)")
            do { _ = try KiroUsageParser.reading(from: text); throw Failure(description: "Expected Kiro needsAuth") }
            catch KiroProviderError.notSignedIn { checks += 1 }
        }
        try expect(KiroProviderError.notSignedIn.providerHealth == .signedOut(KiroProviderError.notSignedIn.errorDescription!),
                   "An expired kiro-cli session reads as signed out, not as a failure to repair")

        // Whichever stream carries the card wins; older CLIs use stdout, newer ones stderr.
        try expect(KiroCLI.usageText(stdout: "", stderr: "Estimated Usage | 5%")?.contains("Estimated") == true, "The card is read from stderr when stdout is empty")
        try expect(KiroCLI.usageText(stdout: "Estimated Usage | 5%", stderr: "warning") == "Estimated Usage | 5%", "The stream with the card heading wins")
        try expect(KiroCLI.usageText(stdout: "  \n", stderr: "") == nil, "Silence is not output")
        try expect(KiroCLI.locateBinary(environment: ["HOME": "/nonexistent-kiro-home"]) == nil, "kiro-cli absent means absent, not signed out")

        // The subprocess path, against stand-in scripts: the real CLI needs a login and a network.
        // `read` proves stdin is /dev/null — inheriting a terminal is how this poll would hang.
        let answering = try makeScript(root.appendingPathComponent("kiro-ok"), body: """
        read ignored
        echo "Estimated Usage | Plan: KIRO PRO" 1>&2
        echo "███ 7% (35 of 500 covered in plan)" 1>&2
        """)
        let text = try KiroCLI.run(binary: answering, timeout: 10)
        try expect(try KiroUsageParser.reading(from: text).credits.usedPercent == 7, "The card is read back off a CLI that answers on stderr, with stdin closed")

        let refusing = try makeScript(root.appendingPathComponent("kiro-out"), body: """
        echo "You are not logged in. Run kiro-cli login." 1>&2
        exit 1
        """)
        do { _ = try KiroCLI.run(binary: refusing, timeout: 10); throw Failure(description: "Expected Kiro needsAuth from exit") }
        catch KiroProviderError.notSignedIn { checks += 1 }

        let wedged = try makeScript(root.appendingPathComponent("kiro-hang"), body: "sleep 60")
        let started = Date()
        do { _ = try KiroCLI.run(binary: wedged, timeout: 1); throw Failure(description: "Expected kiro-cli timeout") }
        catch KiroProviderError.timedOut { checks += 1 }
        try expect(Date().timeIntervalSince(started) < 10, "A wedged CLI is killed, not waited on")
        do { _ = try KiroCLI.run(binary: root.appendingPathComponent("nonexistent-kiro-cli")); throw Failure(description: "Expected launch failure") }
        catch KiroProviderError.notInstalled { checks += 1 }

        // The provider itself, with the CLI injected so no binary is ever spawned for it.
        let policy = ProviderRetryPolicy(provider: .kiro, defaults: defaults)
        let provider = KiroUsageProvider(retryPolicy: policy, readUsage: { card })
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.provider == .kiro && snapshot.planName == "Kiro Pro" && snapshot.remainingPercent == 58, "Kiro snapshot follows the CLI card")
        try expect(snapshot.accountID == nil, "kiro-cli never names the account, so none is claimed")
        let loggedOut = KiroUsageProvider(retryPolicy: policy, readUsage: { throw KiroProviderError.notSignedIn })
        do { _ = try await loggedOut.fetchSnapshot(); throw Failure(description: "Expected Kiro signed out") }
        catch KiroProviderError.notSignedIn { checks += 1 }
    }

    /// An executable stand-in for kiro-cli that ignores the arguments it is handed.
    static func makeScript(_ url: URL, body: String) throws -> URL {
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

// Group C regression checks: MiniMax Coding Plan and the Gemini local token ledger.
// Splice these static functions into Tests/ProviderRegressionTests.swift and add to main():
//     try minimaxParsing()
//     try await minimaxNetworking(root: root, defaults: defaults)
//     try await gemini(root)

    static func minimaxParsing() throws {
        // Coding Plan: the counts are *remaining*, so used is total - remaining.
        let counts = Data(#"""
        {"base_resp":{"status_code":0},"current_subscribe_title":"Max","model_remains":[
          {"model_name":"general","current_interval_total_count":1000,"current_interval_usage_count":250,
           "start_time":1700000000000,"end_time":1700018000000,
           "current_weekly_total_count":5000,"current_weekly_usage_count":4000}]}
        """#.utf8)
        let reading = try MiniMaxUsageParser.reading(from: counts, now: Date(timeIntervalSince1970: 1_700_000_100))
        try expect(reading.plan == "Max", "MiniMax plan name comes from current_subscribe_title")
        try expect(reading.windows.map(\.id) == ["session", "weekly"], "MiniMax windows in headline order")
        try expect(reading.windows[0].usedPercent == 75 && reading.windows[1].usedPercent == 20, "Remaining counts become used percent")
        try expect(reading.windows[0].durationMinutes == 300, "Interval duration comes from start_time/end_time")
        try expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_700_018_000), "A future end_time is the reset")
        try expect(reading.windows[1].durationMinutes == 10_080, "Weekly falls back to a seven-day duration")

        // Token Plan answers percentages instead, and remaining can exceed 100 under a boost.
        let percents = Data(#"""
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"MiniMax-M2","current_interval_remaining_percent":60,"remains_time":900000,
           "current_weekly_remaining_percent":130}]}
        """#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = try MiniMaxUsageParser.reading(from: percents, now: now)
        try expect(plan.windows[0].usedPercent == 40, "Remaining percent becomes used percent")
        try expect(plan.windows[1].usedPercent == 0, "A boosted remaining over 100 never reads as negative use")
        try expect(plan.windows[0].resetsAt == now.addingTimeInterval(900), "remains_time is milliseconds from now")

        // A video schema row sitting first must not become the ring, and an unlimited weekly must.
        let lanes = Data(#"""
        {"model_remains":[
          {"model_name":"video generation","current_interval_total_count":0,"current_interval_usage_count":0,
           "current_interval_status":3,"current_interval_remaining_percent":100},
          {"model_name":"general","current_interval_remaining_percent":10,
           "current_weekly_status":3,"current_weekly_remaining_percent":100}]}
        """#.utf8)
        let mixed = try MiniMaxUsageParser.reading(from: lanes, now: now)
        try expect(mixed.windows.count == 2 && mixed.windows[0].usedPercent == 90, "The text lane is the ring, not the video placeholder")
        try expect(mixed.windows[1].usedPercent == 0 && mixed.windows[1].resetsAt == nil, "An unlimited weekly is empty and never resets")

        // `data` wraps the payload on some hosts; inner keys win.
        let wrapped = Data(#"{"base_resp":{"status_code":0},"data":{"combo_title":"Pro","model_remains":[{"current_interval_total_count":10,"current_interval_usage_count":2}]}}"#.utf8)
        let inner = try MiniMaxUsageParser.reading(from: wrapped, now: now)
        try expect(inner.plan == "Pro" && inner.windows[0].usedPercent == 80, "A data-wrapped payload reads the same")

        for json in ["{}", #"{"model_remains":[]}"#, #"{"model_remains":[{"model_name":"general"}]}"#,
                     #"{"base_resp":{"status_code":1004},"model_remains":[{"current_interval_total_count":10,"current_interval_usage_count":2}]}"#] {
            try rejects({ _ = try MiniMaxUsageParser.reading(from: Data(json.utf8), now: now) }, "Missing or refused MiniMax data is not free quota")
        }
        do {
            _ = try MiniMaxUsageParser.reading(from: Data(#"{"base_resp":{"status_code":401,"status_msg":"unauthorized"}}"#.utf8), now: now)
            throw Failure(description: "Expected MiniMax envelope 401")
        } catch MiniMaxProviderError.unauthorized { checks += 1 }

        try expect(MiniMaxUsageParser.codingPlanToken(from: "sk-api-fixture") == nil, "A pay-as-you-go key has no plan to meter")
        try expect(MiniMaxUsageParser.codingPlanToken(from: " Bearer sk-cp-fixture ") == "sk-cp-fixture", "A pasted Bearer prefix is stripped")
        try expect(MiniMaxUsageParser.codingPlanToken(from: "   ") == nil, "An empty key is not a key")
        try expect(MiniMaxUsageParser.envelopeStatus(in: Data(#"{"base_resp":{"status_code":1004}}"#.utf8)) == 1004, "Envelope status is read from base_resp")
        try expect(MiniMaxUsageParser.isRateLimited(status: 200, envelope: 2045), "Overloaded under HTTP 200 is a throttle")
        try expect(MiniMaxUsageParser.isMissingEndpoint(status: 200, envelope: 1004), "A bearer 1004 means try the other remains path")
        try expect(!MiniMaxUsageParser.isDeadCredential(status: 200, envelope: 1004), "A bearer 1004 is not a dead key")
        try expect(MiniMaxRegion(rawValue: "china") == .china && MiniMaxRegion.allCases.count == 2, "Both MiniMax regions are selectable")
        try expect(MiniMaxRegion.global.apiBase.host == "api.minimax.io" && MiniMaxRegion.china.apiBase.host == "api.minimaxi.com", "Each region has its own API host")
    }

    static func minimaxNetworking(root: URL, defaults: UserDefaults) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let policy = ProviderRetryPolicy(provider: .minimax, defaults: defaults)
        let body = #"{"base_resp":{"status_code":0},"current_subscribe_title":"Max","model_remains":[{"model_name":"general","current_interval_total_count":100,"current_interval_usage_count":30,"current_weekly_total_count":100,"current_weekly_usage_count":90}]}"#
        let provider = MiniMaxUsageProvider(session: session, retryPolicy: policy,
                                            loadAPIKey: { "sk-cp-fixture" }, resolveRegion: { .global })

        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, body)]
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.provider == .minimax && snapshot.planName == "Max", "MiniMax snapshot names the plan")
        try expect(snapshot.windows.map(\.usedPercent) == [70, 10], "Both MiniMax windows are reported")
        let first = FixtureProtocol.requests.last!
        try expect(first.url?.host == "api.minimax.io" && first.url?.path == "/v1/token_plan/remains", "Token Plan is asked first")
        try expect(first.httpMethod == "GET" && first.value(forHTTPHeaderField: "Authorization") == "Bearer sk-cp-fixture", "Bearer key on a GET")

        // A host that does not serve Token Plan falls through to the older Coding Plan path.
        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(404, "{}"), (200, body)]
        _ = try await provider.fetchSnapshot()
        try expect(FixtureProtocol.requests.count == 2, "A missing remains path is retried on the other product")
        try expect(FixtureProtocol.requests.last!.url?.path == "/v1/api/openplatform/coding_plan/remains", "Coding Plan is the fallback path")

        let china = MiniMaxUsageProvider(session: session, retryPolicy: policy,
                                         loadAPIKey: { "sk-cp-fixture" }, resolveRegion: { .china })
        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, body)]
        _ = try await china.fetchSnapshot()
        try expect(FixtureProtocol.requests.last!.url?.host == "api.minimaxi.com", "The China region uses its own host")

        FixtureProtocol.responses = [(401, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected MiniMax 401") }
        catch MiniMaxProviderError.unauthorized { checks += 1 }
        FixtureProtocol.responses = [(503, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected MiniMax 503") }
        catch MiniMaxProviderError.server(503) { checks += 1 }
        FixtureProtocol.responses = [(429, "{}")]
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected MiniMax throttle") }
        catch is ProviderRetryError { checks += 1 }
        try expect(policy.deadline != nil, "MiniMax persists server backoff")
        let count = FixtureProtocol.requests.count
        do { _ = try await provider.fetchSnapshot(); throw Failure(description: "Expected local backoff") }
        catch is ProviderRetryError { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No MiniMax request during backoff")
        policy.reset()

        let unpaid = MiniMaxUsageProvider(session: session, retryPolicy: policy, loadAPIKey: { nil }, resolveRegion: { .global })
        do { _ = try await unpaid.fetchSnapshot(); throw Failure(description: "Expected no MiniMax key") }
        catch MiniMaxProviderError.notSignedIn { checks += 1 }
        let payg = MiniMaxUsageProvider(session: session, retryPolicy: policy, loadAPIKey: { "sk-api-fixture" }, resolveRegion: { .global })
        do { _ = try await payg.fetchSnapshot(); throw Failure(description: "Expected pay-as-you-go key") }
        catch MiniMaxProviderError.payAsYouGoKey { checks += 1 }
        try expect(FixtureProtocol.requests.count == count, "No MiniMax request without a plan key")
    }

    static func gemini(_ root: URL) async throws {
        let manager = FileManager.default
        let now = Date()
        let stamper = ISO8601DateFormatter()
        stamper.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = stamper.string(from: now)

        let cliRoot = root.appendingPathComponent("gemini-tmp-\(UUID().uuidString)")
        let chats = cliRoot.appendingPathComponent("9d2cproject/chats")
        try manager.createDirectory(at: chats, withIntermediateDirectories: true)
        // Header, an unanswered turn, the same id written again with usage, a second call, and a
        // rewind marker: the bill counts ids once, and a rewound call was still charged.
        let session = chats.appendingPathComponent("session.jsonl")
        try Data("""
        {"sessionId":"fixture","projectHash":"9d2c","startTime":"\(stamp)","kind":"main"}
        {"id":"call-1","timestamp":"\(stamp)","type":"gemini","model":"gemini-2.5-pro"}
        {"id":"call-1","timestamp":"\(stamp)","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":900,"output":100,"cached":800,"total":1000}}
        {"id":"call-2","timestamp":"\(stamp)","type":"gemini","tokens":{"total":500}}
        {"id":"call-3","timestamp":"\(stamp)","type":"user","tokens":{"total":9999}}
        {"$set":{"lastUpdated":"\(stamp)"}}
        {"$rewindTo":"call-2"}
        """.utf8).write(to: session)

        let missingDB = root.appendingPathComponent("no-such.db")
        let provider = GeminiUsageProvider(cliRoot: cliRoot, openCodeDatabase: missingDB, hermesDatabase: missingDB,
                                           budget: { 3_000 }, now: { now })
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.provider == .gemini && snapshot.costInfo?.totalTokens == 1500, "Answered calls are counted once each")
        try expect(snapshot.windows.map(\.id) == ["monthly"], "One monthly window")
        try expect(snapshot.windows[0].label == String(localized: "Monthly limit", bundle: .language), "The window reuses the monthly label")
        try expect(snapshot.windows[0].usedPercent == 50, "Tokens are measured against the budget")
        let month = GeminiTokenLedger.calendar.dateInterval(of: .month, for: now)!
        try expect(snapshot.windows[0].resetsAt == month.end, "The window resets when the month does")
        try expect(snapshot.windows[0].durationMinutes == Int((month.duration / 60).rounded()), "The duration is this month's length")
        try expect(snapshot.health == .live, "A readable ledger is live")

        let small = GeminiUsageProvider(cliRoot: cliRoot, openCodeDatabase: missingDB, hermesDatabase: missingDB,
                                        budget: { 100 }, now: { now })
        let capped = try await small.fetchSnapshot()
        try expect(capped.windows[0].usedPercent == 100, "Overrunning the budget never exceeds 100%")

        // A file last written before this month cannot hold this month's calls, so it is skipped
        // without being parsed, however current its records claim to be.
        let stale = chats.appendingPathComponent("stale.jsonl")
        try Data(#"{"id":"old","timestamp":"\#(stamp)","type":"gemini","tokens":{"total":7000}}"#.utf8).write(to: stale)
        let lastMonth = GeminiTokenLedger.calendar.date(byAdding: .month, value: -1, to: GeminiTokenLedger.startOfMonth(now: now))!
        try manager.setAttributes([.modificationDate: lastMonth], ofItemAtPath: stale.path)
        try expect(GeminiTokenLedger.cliTokens(root: cliRoot, now: now) == 1500, "Files untouched this month are not read")

        // An installed tool that has spent nothing is a zero; a tool that was never installed is
        // not a row at all, and with no rows there is nothing to meter.
        let emptyRoot = root.appendingPathComponent("gemini-empty-\(UUID().uuidString)")
        try manager.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try expect(GeminiTokenLedger.cliTokens(root: emptyRoot, now: now) == 0, "An empty CLI root is a zero, not a missing tool")
        try expect(GeminiTokenLedger.cliTokens(root: root.appendingPathComponent("never"), now: now) == nil, "A missing CLI root is a missing tool")
        try expect(GeminiTokenLedger.openCodeTokens(database: missingDB, now: now) == nil, "A missing OpenCode database is a missing tool")
        try expect(GeminiTokenLedger.hermesTokens(database: missingDB, now: now) == nil, "A missing Hermes database is a missing tool")
        let silent = GeminiUsageProvider(cliRoot: root.appendingPathComponent("never"), openCodeDatabase: missingDB,
                                         hermesDatabase: missingDB, budget: { 3_000 }, now: { now })
        do { _ = try await silent.fetchSnapshot(); throw Failure(description: "Expected no Gemini logs") }
        catch GeminiProviderError.noLogs { checks += 1 }

        // Without a ceiling there is no ring to draw, and zero must not become one.
        for value in [0, -5] {
            let unbudgeted = GeminiUsageProvider(cliRoot: cliRoot, openCodeDatabase: missingDB, hermesDatabase: missingDB,
                                                 budget: { value }, now: { now })
            do { _ = try await unbudgeted.fetchSnapshot(); throw Failure(description: "Expected no Gemini budget") }
            catch GeminiProviderError.noBudget { checks += 1 }
        }
        try expect(GeminiProviderError.noBudget.errorDescription == String(localized: "Set a monthly token budget in Settings", bundle: .language), "The budget prompt names Settings")
        if case .unavailable = GeminiProviderError.noBudget.providerHealth { checks += 1 } else {
            throw Failure(description: "A missing budget is unavailable, not signed out")
        }

        // Last month's calls in a file written this month are still last month's bill.
        let old = stamper.string(from: GeminiTokenLedger.startOfMonth(now: now).addingTimeInterval(-86_400))
        let calls = GeminiUsageParser.calls(from: Data("""
        {"id":"a","timestamp":"\(old)","type":"gemini","tokens":{"total":4000}}
        {"id":"b","timestamp":"\(stamp)","type":"gemini","tokens":{"total":25}}
        {"id":"c","timestamp":"\(stamp)","type":"gemini","tokens":{"total":0}}
        """.utf8))
        try expect(calls.count == 3, "Every answered record is decoded")
        try expect(GeminiUsageParser.monthlyTokens(in: calls, now: now) == 25, "Only this month's non-empty calls are billed")
        try expect(GeminiUsageParser.date(from: "2026-09-01T09:12:33Z") != nil, "Plain timestamps parse")
        try expect(GeminiUsageParser.date(from: "2026-09-01T09:12:33.104Z") != nil, "Fractional timestamps parse")
        try expect(GeminiUsageParser.date(from: "not a date") == nil, "A malformed timestamp is not a date")
    }

    static func codenotchUpdates(_ root: URL, _ defaults: UserDefaults) async throws {
        let immediate = try await RefreshDeadline.run(timeout: .seconds(1)) { 42 }
        try expect(immediate == 42, "Refresh completion returns before deadline")
        let suspended = SuspendedRefresh()
        let deadline = Task { try await RefreshDeadline.run(timeout: .milliseconds(30)) { await suspended.wait() } }
        await suspended.waitUntilStarted()
        do { _ = try await deadline.value; throw Failure(description: "Expected refresh timeout") }
        catch let error as URLError { try expect(error.code == .timedOut, "Noncooperative provider cannot keep refresh waiting") }
        await suspended.finish(10)
        let next = try await RefreshDeadline.run(timeout: .seconds(1)) { 20 }
        try expect(next == 20, "Late completion after timeout is dropped without disturbing later refreshes")
        let cancelledWork = SuspendedRefresh()
        let cancelled = Task { try await RefreshDeadline.run(timeout: .seconds(60)) { await cancelledWork.wait() } }
        await cancelledWork.waitUntilStarted()
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(description: "Expected cancellation") }
        catch is CancellationError { checks += 1 }
        await cancelledWork.finish(30)
        func turn(_ text: String) -> ClaudeTranscript.Turn? { ClaudeTranscript.turn(inTail: Data(text.utf8)) }
        try expect(turn(#"{"type":"user","message":{"content":"fixture"}}"#) == .inFlight, "Claude user turn starts work")
        try expect(turn(#"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#) == .inFlight, "Claude tool use continues work")
        try expect(turn(#"{"type":"assistant","message":{"stop_reason":null}}"#) == .inFlight, "Streaming assistant does not falsely complete")
        try expect(turn(#"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#) == .finished, "Claude end turn finishes")
        try expect(turn(#"{"type":"user","message":{"content":[{"text":"[Request interrupted by user]"}]}}"#) == .finished, "Esc ends Claude activity")
        try expect(turn(#"{"type":"user","message":{"content":"<command-name>/cost</command-name>"}}"#) == .finished, "Local slash command does not start Claude work")
        try expect(turn(#"{"type":"user","message":{"content":[{"type":"text","text":"<local-command-stdout>ok</local-command-stdout>"}]}}"#) == .finished, "Local command output does not start Claude work")
        try expect(ClaudeTranscript.projectSlug(forCWD: "/Users/x/Library/Application Support/Claude/.w") == "-Users-x-Library-Application-Support-Claude--w", "Claude project slug dashes every non-alphanumeric character")
        try expect(AppLanguage.systemLanguageCode(preferred: ["tr-TR", "en-US"], available: ["en", "tr", "de"]) == "tr", "System language follows the global preference list")
        try expect(AppLanguage.systemLanguageCode(preferred: ["en-GB"], available: ["en", "tr", "de"]) == "en", "System language falls back to English")
        try expect(AppLanguage.systemLanguageCode(preferred: ["pt-BR", "en"], available: ["en", "pt-BR", "tr"]) == "pt-BR", "System language keeps regional variants")
        try expect(AppLanguage.system.bundleLanguageCode == AppLanguage.systemLanguageCode(), "System choice reads the system language bundle")
        let finished = #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#
        try expect(turn(finished + "\n" + #"{"type":"bridge-session"}"# + "\n" + #"{"type":"user","isSidechain":true}"#) == .finished, "Bookkeeping and subagents cannot restart parent activity")
        try expect(turn("partial line\n" + finished + "\n{unfinished") == .finished, "Partial transcript writes are skipped")
        let projects = root.appendingPathComponent("projects")
        let folder = projects.appendingPathComponent(ClaudeTranscript.projectSlug(forCWD: "/fixture/app"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = folder.appendingPathComponent("fixture-session.jsonl")
        try Data(finished.utf8).write(to: transcript)
        let reader = ClaudeTranscriptReader(projects: projects)
        let first = reader.activity(sessionID: "fixture-session", cwd: "/fixture/app")
        try expect(first?.turn == .finished, "Find Claude transcript by profile project")
        try Data((finished + "\n" + #"{"type":"bridge-session"}"#).utf8).write(to: transcript)
        try expect(reader.activity(sessionID: "fixture-session", cwd: "/fixture/app")?.since == first?.since, "Bookkeeping preserves elapsed state time")
        try expect(ClaudeTranscript.transcript(forSessionID: "../escape", cwd: "/fixture/app", in: projects, scanning: true) == nil, "Registry cannot traverse outside transcript directory")
        // Exercise the registry-to-transcript integration with this fixture process as the live PID.
        let liveProfile = ClaudeProfile(home: root)
        try FileManager.default.createDirectory(at: liveProfile.sessionsDirectory, withIntermediateDirectories: true)
        let liveProjects = liveProfile.directory.appendingPathComponent("projects")
        let liveFolder = liveProjects.appendingPathComponent(ClaudeTranscript.projectSlug(forCWD: "/fixture/app"))
        try FileManager.default.createDirectory(at: liveFolder, withIntermediateDirectories: true)
        try Data(#"{"type":"user","message":{"content":"fixture"}}"#.utf8).write(to: liveFolder.appendingPathComponent("desktop-session.jsonl"))
        let pid = ProcessInfo.processInfo.processIdentifier
        let started = ActivityReader.processStart(pid)!
        var registry: [String: Any] = ["pid": pid, "cwd": "/fixture/app", "startedAt": started.timeIntervalSince1970 * 1000, "sessionId": "desktop-session"]
        let registryFile = liveProfile.sessionsDirectory.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: registry).write(to: registryFile)
        let activityReader = ActivityReader()
        let desktopSessions = await activityReader.readClaudeSessions(profile: liveProfile)
        try expect(desktopSessions.first?.state == .working && desktopSessions.first?.isInferred == true, "Claude desktop registry uses transcript when status is absent")
        registry["status"] = "waiting"
        try JSONSerialization.data(withJSONObject: registry).write(to: registryFile)
        let waitingSessions = await activityReader.readClaudeSessions(profile: liveProfile)
        try expect(waitingSessions.first?.state == .waiting && waitingSessions.first?.isInferred == false, "Explicit registry waiting takes precedence over transcript")
        // A session suspended with ctrl-Z is left out until it is resumed.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let sleeperStart = ActivityReader.processStart(sleeper.processIdentifier)!
        let stoppedRecord: [String: Any] = ["pid": sleeper.processIdentifier, "cwd": "/fixture/app",
                                            "startedAt": sleeperStart.timeIntervalSince1970 * 1000, "status": "idle"]
        let stoppedFile = liveProfile.sessionsDirectory.appendingPathComponent("stopped.json")
        try JSONSerialization.data(withJSONObject: stoppedRecord).write(to: stoppedFile)
        kill(sleeper.processIdentifier, SIGSTOP)
        for _ in 0..<50 where !ActivityReader.isStopped(sleeper.processIdentifier) { try await Task.sleep(for: .milliseconds(20)) }
        try expect(ActivityReader.isStopped(sleeper.processIdentifier), "SIGSTOP is seen as stopped")
        let withStopped = await activityReader.readClaudeSessions(profile: liveProfile)
        try expect(!withStopped.contains { $0.pid == sleeper.processIdentifier }, "A stopped session is left out")
        kill(sleeper.processIdentifier, SIGCONT)
        for _ in 0..<50 where ActivityReader.isStopped(sleeper.processIdentifier) { try await Task.sleep(for: .milliseconds(20)) }
        let resumed = await activityReader.readClaudeSessions(profile: liveProfile)
        try expect(resumed.contains { $0.pid == sleeper.processIdentifier && $0.state == .idle }, "A resumed session is listed again")
        // A session a program started is kept only while somebody can be at it. The sleeper has no
        // tty of its own; whether an application sits above it depends on where the tests run, so
        // only the two unambiguous answers are checked: a non-SDK entrypoint is never asked, and an
        // SDK one follows `isAttended`.
        var sdkRecord = stoppedRecord
        sdkRecord["entrypoint"] = "sdk-ts"
        try JSONSerialization.data(withJSONObject: sdkRecord).write(to: stoppedFile)
        let sdk = await activityReader.readClaudeSessions(profile: liveProfile)
        try expect(sdk.contains { $0.pid == sleeper.processIdentifier } == ActivityReader.isAttended(sleeper.processIdentifier), "An SDK session is listed exactly when attended")
        sdkRecord["entrypoint"] = "cli"
        try JSONSerialization.data(withJSONObject: sdkRecord).write(to: stoppedFile)
        let cli = await activityReader.readClaudeSessions(profile: liveProfile)
        try expect(cli.contains { $0.pid == sleeper.processIdentifier }, "A CLI session is never asked whether it is attended")
        try? FileManager.default.removeItem(at: stoppedFile)
        let renewal = ClaudeTokenRenewal()
        let profile = ClaudeProfile(home: root)
        let now = Date()
        let healthy = await renewal.renew(expiry: now.addingTimeInterval(500), profile: profile, now: now, launch: { _ in throw Failure(description: "Must not launch") })
        try expect(!healthy, "Healthy Claude token does not launch CLI")
        let renewed = await renewal.renew(expiry: now, profile: profile, now: now, launch: { candidate in
            guard candidate == profile else { throw Failure(description: "Wrong renewal profile") }
        })
        try expect(renewed, "Expiring token launches for correct profile")
        let repeatAttempt = await renewal.renew(expiry: now, profile: profile, now: now.addingTimeInterval(700), launch: { _ in })
        try expect(!repeatAttempt, "Failed expiry advancement never triggers repeated renewal")
        let cooldown = await renewal.renew(expiry: now.addingTimeInterval(10), profile: profile, now: now.addingTimeInterval(20), launch: { _ in })
        try expect(!cooldown, "Renewal cooldown spans token changes")
        let failed = await renewal.renew(expiry: now.addingTimeInterval(10), profile: profile, now: now.addingTimeInterval(700), launch: { _ in throw CancellationError() })
        try expect(!failed, "Cancelled renewal is not success")

        let gemini = root.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)
        let creds = Data(#"{"access_token":"cli-fixture","expiry_date":4102444800000}"#.utf8)
        try creds.write(to: gemini.appendingPathComponent("oauth_creds.json"))
        let loaded = try AntigravityCredentials.load(home: root, keychain: { throw SecretError.missing("fixture") })
        try expect(loaded.accessToken == "cli-fixture" && loaded.isCLI, "CLI-only Gemini credentials work without Keychain sign-in")
        try Data(#"{"access_token":"rotated-fixture","expiry_date":4102444800000}"#.utf8).write(to: gemini.appendingPathComponent("oauth_creds.json"))
        let rotated = try AntigravityCredentials.load(home: root, keychain: { throw SecretError.denied("fixture") })
        try expect(rotated.accessToken == "rotated-fixture", "CLI token rotation remains visible after Keychain refusal")
        for invalid in [#"{"access_token":"token"}"#, #"{"access_token":"bad\nheader","expiry_date":4102444800000}"#, #"{"access_token":"token","expiry_date":true}"#] {
            try expect(AntigravityCredentials.decodeCLI(Data(invalid.utf8), omp: false) == nil, "Reject missing expiry and malformed CLI credentials")
        }
        let omp = AntigravityCredentials.decodeCLI(Data(#"{"access":"omp-fixture","expires":4102444800000,"projectId":"fixture-project","email":"fixture@example.test"}"#.utf8), omp: true)!
        try expect(omp.projectId == "fixture-project" && !omp.isExpired, "OMP milliseconds and project decoded")
        let ompDirectory = root.appendingPathComponent(".omp/agent")
        try FileManager.default.createDirectory(at: ompDirectory, withIntermediateDirectories: true)
        var ompDB: OpaquePointer?
        try expect(sqlite3_open(ompDirectory.appendingPathComponent("agent.db").path, &ompDB) == SQLITE_OK, "Open OMP fixture")
        defer { sqlite3_close(ompDB) }
        sqlite3_exec(ompDB, "PRAGMA journal_mode=WAL; CREATE TABLE auth_credentials(provider TEXT, data TEXT, updated_at INTEGER); INSERT INTO auth_credentials VALUES ('google-antigravity', '{\"access\":\"omp-fixture\",\"expires\":4102444800000,\"projectId\":\"fixture-project\"}', 1); INSERT INTO auth_credentials VALUES ('other-provider', '{\"access\":\"wrong-provider\",\"expires\":4102444800000}', 2)", nil, nil, nil)
        let fromOMP = try AntigravityCredentials.load(home: root, keychain: { throw SecretError.missing("fixture") })
        try expect(fromOMP.accessToken == "omp-fixture" && fromOMP.projectId == "fixture-project", "OMP WAL credentials are selected only for google-antigravity")
        let flat = #"{"buckets":[{"modelId":"gemini-test","bucketId":"daily","remainingFraction":0.25,"resetTime":"2027-01-01T00:00:00Z"},{"modelId":"claude-test","bucketId":"daily","remainingFraction":0.5}]}"#
        let standalone = AntigravityProcessLocator.standaloneArguments(token: "fixture-token")
        try expect(standalone.first == "--standalone" && standalone.contains("fixture-token") && standalone.contains("0"), "Standalone server arguments carry the token and an unbound port")
        let spawnedCommand = "/Applications/Antigravity.app/Contents/Resources/bin/language_server " + standalone.joined(separator: " ")
        try expect(AntigravityProcessLocator.servers(fromProcessListing: "4242 " + spawnedCommand).first.map { $0.kind == .app && $0.csrfToken == "fixture-token" } == true, "A server GaugeZ started is found by the process listing like the IDE's own")
        let windows = try AntigravityQuotaParser.remoteWindows(from: Data(flat.utf8))
        try expect(windows.count == 2 && windows[0].remainingPercent == 25 && windows[0].resetsAt != nil, "Daily quota fractions retain distinct model families")
        try rejects({ _ = try AntigravityQuotaParser.remoteWindows(from: Data(#"{"buckets":[{"modelId":"bad","remainingFraction":true}]}"#.utf8)) }, "Boolean cannot become free quota")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        FixtureProtocol.requests = []
        FixtureProtocol.responses = [(200, flat)]
        let provider = AntigravityUsageProvider(remoteSession: session,
            retryPolicy: ProviderRetryPolicy(provider: .antigravity, defaults: defaults),
            localQuota: { throw AntigravityProviderError.noReachableServer }, loadCredentials: { omp },
            readActivity: { AntigravityActivity(requestsToday: 0, lastRequest: nil) })
        let snapshot = try await provider.fetchSnapshot()
        try expect(snapshot.windows.count == 2 && snapshot.accountID == omp.email, "CLI-only Antigravity fetch returns live quota")
        let request = FixtureProtocol.requests.last!
        try expect(request.url?.host == "daily-cloudcode-pa.googleapis.com", "CLI quota uses daily endpoint")
        let fixture = RenewalCredentialFixture()
        FixtureProtocol.responses = [(200, #"{"five_hour":{"utilization":25}}"#), (200, "{}")]
        let claude = ClaudeUsageProvider(profile: liveProfile, session: session,
            retryPolicy: ProviderRetryPolicy(provider: .claude, defaults: defaults),
            loadCredentials: { fixture.read() }, renewSignIn: { _ in fixture.rotate() }, selectedSource: { .claudeCode })
        let recovered = try await claude.fetchSnapshot()
        try expect(recovered.remainingPercent == 75 && fixture.launchCount == 1, "Expired Claude credential renews and fetches successfully")
        try expect(FixtureProtocol.requests.suffix(2).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-fixture" }, "Renewal sends only the new token")
        // URLProtocol may expose the request body as a stream; endpoint and account are verified above.
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
        for name in [".codex-work/auth.json", ".codex-client/sessions"] {
            try fm.createDirectory(at: root.appendingPathComponent(name).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent(".codex-work/auth.json"))
        try fm.createDirectory(at: root.appendingPathComponent(".codex-client/sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".codex-empty"), withIntermediateDirectories: true)
        let codex = CodexProfile.discover(home: root, environment: [:])
        try expect(codex.map(\.provider.rawValue) == ["codex", "codex-client", "codex-work"], "Discover only used Codex homes in stable order")
        try expect(codex[2].authURL == root.appendingPathComponent(".codex-work/auth.json"), "Named Codex home keeps its own auth.json")
        try expect(ProviderID(rawValue: "codex-work")?.displayName == "Codex (work)", "Named Codex ring label")
        try expect(ProviderID(rawValue: "codex-../bad") == nil, "Reject paths in Codex profile IDs")
        try expect(CodexProfile(home: root, environment: ["CODEX_HOME": root.path]).directory.standardizedFileURL.path == root.standardizedFileURL.path, "Default Codex home respects CODEX_HOME")
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

    static func keychainPrompt() throws {
        let permission = PromptPermission()
        try expect(!permission.take(), "Nothing is owed until somebody asks")
        permission.grant()
        try expect(permission.take(), "Asking owes exactly one read")
        try expect(!permission.take(), "A second read spent the same click")
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let timed = PromptPermission(now: { clock.now })
        timed.grant()
        clock.now = clock.now.addingTimeInterval(PromptPermission.window + 1)
        try expect(!timed.take(), "An unspent permission lapses")

        var prompted = false
        var rescuedService: String?
        KeychainSecret.copyMatchingForTesting = { _, interactive in
            prompted = interactive
            return (errSecInteractionNotAllowed, nil)
        }
        KeychainSecret.rescueForTesting = { service, _ in
            rescuedService = service
            return Data("rescued".utf8)
        }
        defer {
            KeychainSecret.copyMatchingForTesting = nil
            KeychainSecret.rescueForTesting = nil
        }
        let match = ClaudeKeychain.Match(modifiedAt: nil, persistentRef: Data([1]),
                                         service: "Claude Code-credentials", account: "fixture")
        let data = try ClaudeKeychain.read(match, interactive: false)
        try expect(!prompted && rescuedService == "Claude Code-credentials" && data == Data("rescued".utf8),
                   "A refused background read is rescued through the security tool")
        KeychainSecret.rescueForTesting = { _, _ in nil }
        try rejects({ _ = try ClaudeKeychain.read(match, interactive: false) }, "A refused read without rescue stays a denial")
    }

    static func emptiedClaudeLogin(_ root: URL) throws {
        let profile = ClaudeProfile(provider: ProviderID(rawValue: "claude-emptied")!, home: root)
        try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        try Data(#"{"claudeAiOauth":{"accessToken":"","expiresAt":0}}"#.utf8).write(to: profile.credentialsFile)
        do {
            _ = try ClaudeCredentialReader.load(profile: profile, match: nil)
            throw Failure(description: "Expected emptied credential to throw")
        } catch ClaudeProviderError.signedOutByOwner {
            checks += 1
        }
        guard case .stale = ClaudeProviderError.signedOutByOwner.providerHealth else {
            throw Failure(description: "An emptied Claude login keeps the last reading as stale")
        }
        checks += 1
    }

    static func automaticHeadline() throws {
        let exhausted = UsageWindow(id: "session", label: "5-hour", usedPercent: 100, resetsAt: nil, durationMinutes: 300)
        let weekly = UsageWindow(id: "weekly", label: "Weekly", usedPercent: 40, resetsAt: nil, durationMinutes: 10_080)
        try expect(UsageSnapshot.automaticHeadline(in: [exhausted, weekly])?.id == "weekly",
                   "An exhausted window does not headline while another has remaining")
        let other = UsageWindow(id: "other", label: "Other", usedPercent: 100, resetsAt: nil, durationMinutes: nil)
        try expect(UsageSnapshot.automaticHeadline(in: [exhausted, other])?.id == "session",
                   "When every window is exhausted the tightest still leads")
        let snapshot = UsageSnapshot(provider: .antigravity, accountID: nil, planName: nil,
                                     windows: [exhausted, weekly], observedAt: .now, source: "fixture", health: .live)
        try expect(snapshot.headlineWindow?.id == "weekly", "Automatic snapshot headline skips exhausted windows")
        var selected = snapshot
        selected.headlineWindowID = "session"
        try expect(selected.headlineWindow?.id == "session", "An explicit headline is honoured even when exhausted")
    }

    static func usageEvents() throws {
        func window(_ id: String, used: Double, resetsAt: Date? = nil) -> UsageWindow {
            UsageWindow(id: id, label: id == "session" ? "5-hour" : "Weekly", usedPercent: used, resetsAt: resetsAt, durationMinutes: 300)
        }
        func snapshot(_ windows: [UsageWindow], health: ProviderHealth = .live) -> UsageSnapshot {
            UsageSnapshot(provider: .claude, accountID: nil, planName: nil, windows: windows,
                          observedAt: .now, source: "fixture", health: health)
        }

        var watcher = UsageEventWatcher()
        try expect(watcher.observe(snapshot([window("session", used: 100)])).isEmpty,
                   "The first observation of a limit event watcher never announces")
        try expect(watcher.observe(snapshot([window("session", used: 100)])).isEmpty,
                   "A window already exhausted does not announce again")
        try expect(watcher.observe(snapshot([window("session", used: 97)])).isEmpty,
                   "A recovery under the hysteresis floor keeps the limit latched")
        try expect(watcher.observe(snapshot([window("session", used: 100)])).isEmpty,
                   "Re-crossing inside the hysteresis band is not a new crossing")
        try expect(watcher.observe(snapshot([window("session", used: 94)])).isEmpty,
                   "Climbing clear of the floor clears the latch without an event")
        let reached = watcher.observe(snapshot([window("session", used: 100)]))
        try expect(reached.map(\.kind) == [.limitReached], "A window reaching zero announces the limit")
        try expect(reached.first?.window.id == "session", "The limit event names its window")
        try expect(watcher.observe(snapshot([window("session", used: 99.8)])).isEmpty,
                   "Jitter under the hysteresis floor keeps the limit latched")
        try expect(watcher.observe(snapshot([window("session", used: 100)])).isEmpty,
                   "A re-exhaustion inside the jitter band does not announce twice")

        var rolloverWatcher = UsageEventWatcher()
        let rollover = Date().addingTimeInterval(3600)
        // Remaining stays at or above 50 throughout, so the slack is what decides, not the
        // freshness gate; and the rise stays under the refill jump.
        _ = rolloverWatcher.observe(snapshot([window("session", used: 60, resetsAt: Date().addingTimeInterval(600))]))
        try expect(rolloverWatcher.observe(snapshot([window("session", used: 50, resetsAt: Date().addingTimeInterval(720))])).isEmpty,
                   "A reset time sliding by minutes is not a rollover")
        let reset = rolloverWatcher.observe(snapshot([window("session", used: 5, resetsAt: rollover)]))
        try expect(reset.map(\.kind) == [.limitReset], "A reset time pushed out by the window length announces the reset")
        try expect(reset.first?.window.remainingPercent == 95, "The reset event carries the fresh reading")
        try expect(rolloverWatcher.observe(snapshot([window("session", used: 8, resetsAt: rollover)])).isEmpty,
                   "The reset announces once per rollover")
        let idleRollover = rollover.addingTimeInterval(5 * 3600)
        try expect(rolloverWatcher.observe(snapshot([window("session", used: 8, resetsAt: idleRollover)])).isEmpty,
                   "A window left idle since its last reset has nothing to reset")
        _ = rolloverWatcher.observe(snapshot([window("session", used: 40, resetsAt: idleRollover)]))
        try expect(rolloverWatcher.observe(snapshot([window("session", used: 2, resetsAt: idleRollover.addingTimeInterval(5 * 3600))])).map(\.kind) == [.limitReset],
                   "Using the fresh window again makes its next rollover a reset")

        var slideWatcher = UsageEventWatcher()
        _ = slideWatcher.observe(snapshot([window("session", used: 80, resetsAt: Date().addingTimeInterval(600))]))
        try expect(slideWatcher.observe(snapshot([window("session", used: 40, resetsAt: Date().addingTimeInterval(720))])).isEmpty,
                   "Remaining climbing under a reset time that only slid is not a reset")

        var refillWatcher = UsageEventWatcher()
        // Remaining stays above 50, so the jump size is what decides.
        _ = refillWatcher.observe(snapshot([window("session", used: 45)]))
        try expect(refillWatcher.observe(snapshot([window("session", used: 40)])).isEmpty,
                   "A small rise in remaining is not a reset")
        try expect(refillWatcher.observe(snapshot([window("session", used: 5)])).map(\.kind) == [.limitReset],
                   "Remaining leaping back announces a reset when no reset time is reported")

        var unusedWatcher = UsageEventWatcher()
        _ = unusedWatcher.observe(snapshot([window("session", used: 10, resetsAt: Date().addingTimeInterval(600))]))
        try expect(unusedWatcher.observe(snapshot([window("session", used: 0, resetsAt: rollover)])).isEmpty,
                   "A window that was never used does not announce a reset")

        var staleWatcher = UsageEventWatcher()
        _ = staleWatcher.observe(snapshot([window("session", used: 50)]))
        try expect(staleWatcher.observe(snapshot([window("session", used: 100)], health: .stale("fixture"))).isEmpty,
                   "Stale readings never announce transitions")

        var mutedWatcher = UsageEventWatcher()
        _ = mutedWatcher.observe(snapshot([window("session", used: 50)]))
        try expect(mutedWatcher.observe(snapshot([window("session", used: 100)]), muted: true).isEmpty,
                   "A muted provider announces nothing")
        try expect(mutedWatcher.observe(snapshot([window("session", used: 100)])).isEmpty,
                   "Unmuting does not replay the transition missed while muted")

        var forgottenWatcher = UsageEventWatcher()
        _ = forgottenWatcher.observe(snapshot([window("session", used: 80)]))
        forgottenWatcher.forget(.claude)
        try expect(forgottenWatcher.observe(snapshot([window("session", used: 100)])).isEmpty,
                   "A forgotten provider seeds again without announcing")

        var weeklyWatcher = UsageEventWatcher()
        _ = weeklyWatcher.observe(snapshot([window("session", used: 50), window("weekly", used: 90)]))
        let weekly = weeklyWatcher.observe(snapshot([window("session", used: 50), window("weekly", used: 100)]))
        try expect(weekly.map(\.kind) == [.limitReached] && weekly.first?.window.id == "weekly",
                   "Each window announces on its own key")
        try expect(weeklyWatcher.observe(snapshot([window("session", used: 50), window("weekly", used: 100)])).isEmpty,
                   "A settled window exhausting again stays quiet")
    }

    static func antigravityUnifiedParser() throws {
        let grouped = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","displayName":"5-hour Limit","remainingFraction":0.4}]}]}"#
        let local = try AntigravityQuotaParser.windows(fromQuotaSummary: Data(grouped.utf8))
        let remote = try AntigravityQuotaParser.remoteWindows(from: Data(grouped.utf8))
        try expect(local.map(\.id) == remote.map(\.id) && local.first?.id == "antigravity-gemini-5h",
                   "Local and remote grouped payloads share window IDs")
        try expect(abs((local.first?.remainingPercent ?? 0) - 40) < 0.0001, "Grouped remaining fraction")
        let wrapped = #"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","displayName":"5-hour Limit","remainingFraction":0.4}]}]}}"#
        let fromResponse = try AntigravityQuotaParser.remoteWindows(from: Data(wrapped.utf8))
        try expect(fromResponse.map(\.id) == local.map(\.id), "response.groups uses the same IDs as a bare groups payload")
    }

    static func codexResetCredits() throws {
        let json = """
        {"available_count":2,"credits":[
          {"id":"credit-a","reset_type":"codex_rate_limits","status":"available",
           "expires_at":"2026-07-12T01:33:14Z"},
          {"id":"credit-b","status":"available","expires_at":"2026-07-18T08:00:00Z"}]}
        """
        let result = try CodexWebUsage.resetCredits(from: Data(json.utf8))
        let firstExpiry = ISO8601DateFormatter().date(from: "2026-07-12T01:33:14Z")
        try expect(result.availableCount == 2 && result.nextExpiry == firstExpiry,
                   "Count and soonest expiry from the credits payload")
        let truncated = try CodexWebUsage.resetCredits(from: Data(#"{"available_count":5,"credits":[{"status":"available","expires_at":"2026-07-12T01:33:14Z"}]}"#.utf8))
        try expect(truncated.availableCount == 5 && truncated.credits.count == 1, "available_count wins when the list is shorter")
        let unknown = try CodexWebUsage.resetCredits(from: Data(#"{"unexpected":true}"#.utf8))
        try expect(unknown.availableCount == 0, "An unfamiliar JSON body is an empty credits list")
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
        row["isSubagent"] = true
        try expect(try parse() == nil, "Nested Cursor agents never become waiting sessions")
        row["isSubagent"] = "1"
        try expect(try parse() == nil, "String subagent marker is recognized")
        row.removeValue(forKey: "isSubagent")
        row.removeValue(forKey: "unfinishedRunAt")
        row["lastUpdatedAt"] = now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000
        try expect(try parse() == nil, "Old approval from previous Cursor launch is retired")
        row["lastUpdatedAt"] = now.addingTimeInterval(-1800).timeIntervalSince1970 * 1000
        try expect(try parse()?.state == .waiting, "Current-launch approval survives a long wait")
        row["lastUpdatedAt"] = now.addingTimeInterval(-10).timeIntervalSince1970 * 1000
        try expect(try parse(now)?.state == .waiting, "Recent approval survives editor restart")
        row.removeValue(forKey: "lastUpdatedAt")
        row["createdAt"] = now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000
        try expect(try parse() == nil, "Creation date retires approval without checkpoints")
        row.removeValue(forKey: "createdAt")
        try expect(try parse()?.state == .waiting, "Undated approval remains visible")
        row["lastUpdatedAt"] = now.addingTimeInterval(60).timeIntervalSince1970 * 1000
        try expect(try parse() == nil, "Future-dated approval is not live")
        row["lastUpdatedAt"] = now.addingTimeInterval(-10).timeIntervalSince1970 * 1000
        row["lastUpdatedAt"] = Date().timeIntervalSince1970 * 1000
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
        sqlite3_exec(db, "ALTER TABLE composerHeaders ADD COLUMN isSubagent INTEGER DEFAULT 0; UPDATE composerHeaders SET isSubagent = 1", nil, nil, nil)
        let nested = await ActivityReader().readCursorSessions(launchedAt: launch, store: dbURL)
        try expect(nested.isEmpty, "SQLite-only subagent marker excludes nested agents")
        sqlite3_exec(db, "UPDATE composerHeaders SET isSubagent = 0", nil, nil, nil)
        let parent = await ActivityReader().readCursorSessions(launchedAt: launch, store: dbURL)
        try expect(parent.count == 1, "Modern Cursor schema retains parent chats")
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
        let request = FixtureProtocol.requests.first { $0.url == CodexWebUsage.endpoint }!
        try expect(request.url == CodexWebUsage.endpoint && request.httpMethod == "GET", "Official usage route, read-only")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer codex-fixture" && request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-fixture", "Codex account headers")
        policy.reset()
        FixtureProtocol.requests = []
        FixtureProtocol.responses = [
            (200, #"{"rate_limit":{"primary_window":{"limit_window_seconds":18000,"used_percent":40}}}"#),
            (200, #"{"available_count":2,"credits":[{"status":"available","expires_at":"2026-07-12T01:33:14Z"}]}"#)
        ]
        let withCredits = try await provider.fetchSnapshot()
        try expect(withCredits.resetCredits?.availableCount == 2, "Unused Codex resets attach to the snapshot")
        try expect(FixtureProtocol.requests.contains { $0.url == CodexWebUsage.resetCreditsEndpoint }, "Reset credits use the official ChatGPT route")
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
        let namedProfile = CodexProfile(provider: ProviderID(rawValue: "codex-work")!, home: root, environment: [:])
        let namedMissing = CodexUsageProvider(profile: namedProfile, session: session, retryPolicy: policy, locateExecutable: { nil }, loadCredential: { nil })
        do { _ = try await namedMissing.fetchSnapshot(); throw Failure(description: "Expected named profile sign-in guidance") }
        catch CodexProviderError.profileNotSignedIn(let guidance) {
            try expect(guidance.contains("codex-work"), "A named Codex home says how to sign it in")
            try expect(CodexProviderError.profileNotSignedIn(guidance).providerHealth == .signedOut(guidance), "A signed-out named Codex home is signed out, not uninstalled")
        }
        let namedAPIKey = CodexUsageProvider(profile: namedProfile, session: session, retryPolicy: policy, locateExecutable: { nil }, loadCredential: { throw CodexProviderError.notSignedIn })
        do { _ = try await namedAPIKey.fetchSnapshot(); throw Failure(description: "Expected named profile sign-in guidance") }
        catch CodexProviderError.profileNotSignedIn { checks += 1 }
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

/// Holds a provider reply past cancellation to exercise the real completion race.
private actor SuspendedRefresh {
    private var continuation: CheckedContinuation<Int, Never>?
    func wait() async -> Int { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func finish(_ value: Int) { continuation?.resume(returning: value); continuation = nil }
}

private final class RenewalCredentialFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var rotated = false
    private var count = 0
    var launchCount: Int { lock.withLock { count } }
    func rotate() { lock.withLock { rotated = true; count += 1 } }
    func read() -> ClaudeCredential {
        lock.withLock {
            ClaudeCredential(accessToken: rotated ? "renewed-fixture" : "expired-fixture",
                expiresAt: rotated ? .distantFuture : .distantPast, subscriptionType: nil, sourceDescription: "fixture")
        }
    }
}
