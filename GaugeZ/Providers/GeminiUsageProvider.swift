// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import Foundation
import SQLite3

/// Tokens spent against a bare Gemini API key this calendar month, measured against a budget the
/// user sets in Settings.
///
/// There is no endpoint behind this provider. Google meters an API key on the billing account and
/// publishes nothing an app could read, so the only record of a call is the one the tool that made
/// it wrote afterwards: Gemini CLI's chat recordings, and the OpenCode and Hermes databases. All
/// three are read locally and read-only; nothing is sent anywhere, and the key itself is never read.
///
/// The ceiling is the user's own number rather than a limit Google set, so without one there is no
/// ring to draw and the provider says so instead of inventing a percentage.
actor GeminiUsageProvider: UsageProviding {
    private let cliRoot: URL
    private let openCodeDatabase: URL
    private let hermesDatabase: URL
    /// Read fresh on every fetch rather than captured once: the user can change the budget while
    /// the app runs, and the ring has to follow.
    private let budget: @Sendable () -> Int
    private let now: @Sendable () -> Date

    init(cliRoot: URL = GeminiTokenLedger.cliSessionsRoot,
         openCodeDatabase: URL = GeminiTokenLedger.openCodeDatabase,
         hermesDatabase: URL = GeminiTokenLedger.hermesDatabase,
         budget: @escaping @Sendable () -> Int = { UserDefaults.standard.integer(forKey: "geminiMonthlyTokenBudget") },
         now: @escaping @Sendable () -> Date = { .now }) {
        self.cliRoot = cliRoot
        self.openCodeDatabase = openCodeDatabase
        self.hermesDatabase = hermesDatabase
        self.budget = budget
        self.now = now
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        let budget = budget()
        guard budget > 0 else { throw GeminiProviderError.noBudget }
        let now = now()

        // A reader answering nil means its tool was never installed here, which is not the same
        // as a zero: with no logs at all there is genuinely nothing being metered.
        let readings = [
            GeminiTokenLedger.cliTokens(root: cliRoot, now: now),
            GeminiTokenLedger.openCodeTokens(database: openCodeDatabase, now: now),
            GeminiTokenLedger.hermesTokens(database: hermesDatabase, now: now)
        ].compactMap { $0 }
        guard !readings.isEmpty else { throw GeminiProviderError.noLogs }

        let tokens = readings.reduce(0, +)
        let month = GeminiTokenLedger.calendar.dateInterval(of: .month, for: now)
        let window = UsageWindow(
            id: "monthly",
            label: String(localized: "Monthly limit", bundle: .language),
            usedPercent: min(100, Double(tokens) / Double(budget) * 100),
            resetsAt: month?.end,
            durationMinutes: month.map { Int(($0.duration / 60).rounded()) }
        )
        return UsageSnapshot(
            provider: .gemini,
            accountID: nil,
            planName: nil,
            windows: [window],
            observedAt: now,
            source: "Local Gemini CLI, OpenCode and Hermes logs · budget you set",
            health: .live,
            costInfo: ProviderCostInfo(totalTokens: tokens)
        )
    }
}

/// The three local logs the token count is added up from. Each reader answers `nil` when its tool
/// has no state on disk, and a token count for this calendar month otherwise.
enum GeminiTokenLedger {
    static var cliSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp")
    }

    static var openCodeDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db")
    }

    static var hermesDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/state.db")
    }

    /// Local and Gregorian, deliberately: `Calendar.current` would follow the user's chosen
    /// calendar identifier too, and a non-Gregorian month is not the month Google bills.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func startOfMonth(now: Date) -> Date {
        calendar.dateInterval(of: .month, for: now)?.start ?? now
    }

    /// One session file can be tens of megabytes after a long month; a whole tree of them must
    /// never be held in memory at once, so each is streamed and bounded.
    private static let byteCapPerFile = 32 * 1_048_576
    private static let fileCap = 4_000

    // MARK: - Gemini CLI

    /// Gemini CLI appends JSONL chat recordings under `<root>/<projectHash>/chats/*.jsonl`.
    static func cliTokens(root: URL, now: Date) -> Int? {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        let startOfMonth = startOfMonth(now: now)
        var tokens = 0
        var files = 0
        for project in projects {
            let chats = project.appendingPathComponent("chats")
            guard let sessions = try? manager.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for session in sessions where session.pathExtension == "jsonl" {
                guard files < fileCap else { return tokens }
                // Append-only, so no record inside can be newer than the file itself: one that
                // was last written before this month cannot contribute and is not parsed.
                let modified = try? session.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let modified, modified < startOfMonth { continue }
                files += 1
                tokens += GeminiUsageParser.monthlyTokens(in: calls(inSessionFile: session), now: now)
            }
        }
        return tokens
    }

    /// Streams one recording in chunks, never loading the file whole, and stops at the byte cap.
    private static func calls(inSessionFile url: URL) -> [String: GeminiTokenCall] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        var answered: [String: GeminiTokenCall] = [:]
        var buffer = Data()
        var read = 0
        while read < byteCapPerFile, let chunk = try? handle.read(upToCount: 262_144), !chunk.isEmpty {
            read += chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                GeminiUsageParser.accumulate(line: buffer[buffer.startIndex..<newline], into: &answered)
                buffer = buffer[buffer.index(after: newline)...]
            }
            // A single line longer than the cap is not a record this reader understands.
            if buffer.count > byteCapPerFile { return answered }
        }
        GeminiUsageParser.accumulate(line: buffer[...], into: &answered)
        return answered
    }

    // MARK: - OpenCode and Hermes

    /// OpenCode keeps one row per message in `opencode.db`, with the counts as JSON in `data`.
    /// `providerID == "google"` is its name for the bare API key; `google-vertex` is Vertex AI,
    /// billed against a GCP project rather than this key, so it must not be added here.
    ///
    /// Summing in SQL rather than in Swift keeps the read to a single row however long the user
    /// has been using OpenCode. `total` is authoritative when present, and the components are the
    /// fallback because `input` there excludes the cache.
    static func openCodeTokens(database: URL, now: Date) -> Int? {
        let milliseconds = Int(startOfMonth(now: now).timeIntervalSince1970 * 1000)
        return sum(in: database, sql: """
            SELECT COALESCE(SUM(CASE WHEN COALESCE(json_extract(data, '$.tokens.total'), 0) > 0
                                     THEN json_extract(data, '$.tokens.total')
                                     ELSE COALESCE(json_extract(data, '$.tokens.input'), 0)
                                        + COALESCE(json_extract(data, '$.tokens.output'), 0)
                                        + COALESCE(json_extract(data, '$.tokens.reasoning'), 0)
                                        + COALESCE(json_extract(data, '$.tokens.cache.read'), 0)
                                        + COALESCE(json_extract(data, '$.tokens.cache.write'), 0)
                                END), 0)
            FROM message
            WHERE json_extract(data, '$.role') = 'assistant'
              AND json_extract(data, '$.providerID') = 'google'
              AND time_created >= \(milliseconds)
            """)
    }

    /// Hermes keeps a running total per session and model. `billing_provider == "gemini"` is its
    /// id for Google AI Studio, which is the bare API key, and it survives a base-url override.
    ///
    /// `reasoning_tokens` is left out on purpose: Hermes counts reasoning inside `output_tokens`,
    /// so adding it back would bill every thinking model twice. `last_seen` is the only timestamp
    /// a row has, so a session straddling month end lands wholly in the month of its last call.
    static func hermesTokens(database: URL, now: Date) -> Int? {
        let seconds = Int(startOfMonth(now: now).timeIntervalSince1970)
        return sum(in: database, sql: """
            SELECT COALESCE(SUM(COALESCE(input_tokens, 0) + COALESCE(cache_read_tokens, 0)
                              + COALESCE(cache_write_tokens, 0) + COALESCE(output_tokens, 0)), 0)
            FROM session_model_usage
            WHERE billing_provider = 'gemini' AND last_seen >= \(seconds)
            """)
    }

    /// `nil` when the database is absent or the table is not the one expected; a total otherwise.
    private static func sum(in database: URL, sql: String) -> Int? {
        guard let db = ReadOnlySQLite.open(path: database.path) else { return nil }
        defer { sqlite3_close(db) }
        guard let first = ReadOnlySQLite.rows(in: db, sql: sql, columns: 1).first?.first else { return nil }
        return Int(first) ?? 0
    }
}

/// One answered Gemini CLI call: the record that carries the usage the API reported.
struct GeminiTokenCall: Equatable, Sendable {
    let id: String
    let at: Date
    let tokens: Int
}

/// Parses Gemini CLI's JSONL chat recordings. Line one is a header; everything after is a message
/// record, a `$set` patch or a `$rewindTo` marker:
///
/// ```
/// {"id":"c7f2…","timestamp":"2026-09-01T09:12:41.402Z","type":"gemini","model":"gemini-2.5-pro",
///  "tokens":{"input":12345,"output":218,"cached":11000,"thoughts":64,"tool":0,"total":12627}}
/// ```
///
/// Two rules the file's shape forces:
///
/// - A `gemini` record is written when the turn starts, without `tokens`, and written *again*
///   with the same `id` once usage arrives. Counting lines instead of ids double-counts every
///   answered call, so the later record for an id wins.
/// - `$rewindTo` un-does the transcript, not the bill: a rewound call was still charged.
///
/// `total` is the field to read — it already is input + output + thoughts + tool, and `cached` is
/// a subset of `input`, so summing the parts would count the cache twice.
enum GeminiUsageParser {
    /// Folds one line into the per-id table. Headers, patches and unanswered turns decode into a
    /// record of nils and are dropped here rather than by a second pass.
    static func accumulate(line: Data, into answered: inout [String: GeminiTokenCall]) {
        guard !line.isEmpty,
              let record = try? JSONDecoder().decode(Record.self, from: line),
              let id = record.id, record.type == "gemini",
              let tokens = record.tokens?.total,
              let stamp = record.timestamp, let at = date(from: stamp)
        else { return }
        answered[id] = GeminiTokenCall(id: id, at: at, tokens: tokens)
    }

    /// Whole-file convenience for small recordings and for tests; the provider streams instead.
    static func calls(from data: Data) -> [String: GeminiTokenCall] {
        var answered: [String: GeminiTokenCall] = [:]
        for line in data.split(separator: 0x0A) { accumulate(line: Data(line), into: &answered) }
        return answered
    }

    /// A call with no tokens was aborted before the model answered; it cost nothing, so it is not
    /// counted. Months are local, because the user's month is what the budget is set in.
    static func monthlyTokens(in calls: [String: GeminiTokenCall], now: Date,
                              calendar: Calendar = GeminiTokenLedger.calendar) -> Int {
        calls.values.reduce(0) { total, call in
            guard call.tokens > 0, calendar.isDate(call.at, equalTo: now, toGranularity: .month) else { return total }
            return total + call.tokens
        }
    }

    /// The CLI writes fractional seconds, but not on every record, and `ISO8601DateFormatter`
    /// rejects the string when the option does not match the text exactly.
    static func date(from value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    private struct Record: Decodable {
        let id: String?
        let type: String?
        let timestamp: String?
        let tokens: Tokens?
    }

    private struct Tokens: Decodable {
        let total: Int?
    }
}

enum GeminiProviderError: LocalizedError, ProviderHealthDescribing {
    case noBudget
    case noLogs

    var errorDescription: String? {
        switch self {
        case .noBudget: String(localized: "Set a monthly token budget in Settings", bundle: .language)
        case .noLogs: String(localized: "No Gemini CLI, OpenCode, or Hermes logs found.", bundle: .language)
        }
    }

    // Neither state is a sign-in or a network problem: nothing is wrong, there is just nothing
    // to meter yet.
    var providerHealth: ProviderHealth {
        .unavailable(errorDescription ?? String(localized: "Gemini API unavailable", bundle: .language))
    }
}
