import Foundation
import Darwin
import SQLite3

struct ActivitySession: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case working = "Working"
        case waiting = "Needs your input"
        case idle = "Idle"
        case unknown = "Activity unknown"
    }
    let id: String
    let provider: ProviderID
    let name: String
    let project: String
    let state: State
    let waitingReason: String?
    /// When the reported state began, or the last evidence of it.
    let since: Date?
    /// The state was inferred from recent writes rather than reported by the tool.
    let isInferred: Bool

    init(id: String, provider: ProviderID, name: String, project: String, state: State,
         waitingReason: String?, since: Date? = nil, isInferred: Bool = false) {
        self.id = id
        self.provider = provider
        self.name = name
        self.project = project
        self.state = state
        self.waitingReason = waitingReason
        self.since = since
        self.isInferred = isInferred
    }
}

/// Opt-in, local metadata only. Session contents and credentials are never read.
actor ActivityReader {
    /// ctime-style `procStart` values are written in UTC.
    private static let procStartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    func readClaudeSessions(profile: ClaudeProfile = ClaudeProfile()) -> [ActivitySession] {
        let directory = profile.sessionsDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.prefix(256).compactMap { url in
            guard !Task.isCancelled,
                  let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) < 65_536,
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (record["pid"] as? NSNumber)?.int32Value, pid > 0,
                  let cwd = record["cwd"] as? String,
                  let processStart = Self.processStart(pid) else { return nil }
            let registered: Date?
            if let millis = (record["startedAt"] as? NSNumber)?.doubleValue, millis.isFinite {
                registered = Date(timeIntervalSince1970: millis / 1000)
            } else if let raw = record["procStart"] as? String {
                registered = Self.procStartFormatter.date(from: raw.split(separator: " ").joined(separator: " "))
            } else { registered = nil }
            // Refuse a stale record for a PID that has since been recycled.
            guard let registered, abs(registered.timeIntervalSince(processStart)) < 300 else { return nil }
            let status = record["status"] as? String ?? ""
            let tempo = record["tempo"] as? String ?? ""
            let state: ActivitySession.State
            if tempo == "blocked" || status == "waiting" { state = .waiting }
            else if tempo == "active" || status == "busy" { state = .working }
            else if tempo == "idle" || status == "idle" { state = .idle }
            else { state = .unknown }
            let project = URL(fileURLWithPath: cwd).lastPathComponent
            let statusMillis = (record["statusUpdatedAt"] as? NSNumber)?.doubleValue ?? (record["updatedAt"] as? NSNumber)?.doubleValue
            let since = statusMillis.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            return ActivitySession(id: "\(profile.provider.rawValue)-\(pid)", provider: profile.provider,
                                   name: String((record["name"] as? String ?? project).prefix(100)),
                                   project: project, state: state,
                                   waitingReason: (record["waitingFor"] as? String ?? record["needs"] as? String).map { String($0.prefix(160)) },
                                   since: since)
        }.sorted {
            let rank: [ActivitySession.State: Int] = [.waiting: 0, .working: 1, .unknown: 2, .idle: 3]
            if rank[$0.state] != rank[$1.state] { return rank[$0.state, default: 3] < rank[$1.state, default: 3] }
            return $0.id < $1.id
        }
    }

    /// Read-only SQLite with WAL support: immutable mode would miss recent agent writes.
    func readCursorSessions(launchedAt: Date?, store: URL = CursorLocalSession.stateDatabaseURL) -> [ActivitySession] {
        guard launchedAt != nil, let db = ReadOnlySQLite.open(path: store.path) else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM composerHeaders WHERE isArchived = 0 ORDER BY recency DESC LIMIT 256",
                                -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var sessions: [ActivitySession] = []
        while !Task.isCancelled, sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_bytes(statement, 0) < 65_536,
                  let text = sqlite3_column_text(statement, 0),
                  let session = CursorActivityParser.session(from: Data(String(cString: text).utf8), launchedAt: launchedAt)
            else { continue }
            sessions.append(session)
        }
        return Self.prioritized(sessions)
    }

    /// Grok publishes no status field. What it does is append to a session's `updates.jsonl`
    /// while a turn runs, so a write within this window is work happening now; an older one is a
    /// TUI sitting idle. It cannot tell a long think from a turn that just ended, so it errs short.
    static let grokStaleAfter: TimeInterval = 45

    func readGrokSessions(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = .now) -> [ActivitySession] {
        let activeURL = home.appendingPathComponent(".grok/active_sessions.json")
        guard let data = try? Data(contentsOf: activeURL),
              let active = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let sessionsRoot = home.appendingPathComponent(".grok/sessions")

        let sessions: [ActivitySession] = active.prefix(16).compactMap { item in
            guard let sid = item["session_id"] as? String, !sid.isEmpty, !sid.contains("/"),
                  let pidNum = item["pid"] as? NSNumber,
                  let cwd = item["cwd"] as? String else { return nil }
            let pid = pidNum.int32Value
            guard pid > 0, let processStart = Self.processStart(pid) else { return nil }
            // A pid handed to another process since the TUI registered is a dead session, not a
            // live one; the registration time is seconds after the real start, so allow slack.
            if let opened = Self.grokDate(item["opened_at"]), abs(processStart.timeIntervalSince(opened)) > 300 {
                return nil
            }

            let project = URL(fileURLWithPath: cwd).lastPathComponent
            let sessionDir = Self.grokSessionDirectory(id: sid, cwd: cwd, under: sessionsRoot)
            var name = project
            if let sessionDir,
               let summaryData = try? Data(contentsOf: sessionDir.appendingPathComponent("summary.json")),
               let summary = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any],
               let title = (summary["session_summary"] as? String ?? summary["generated_title"] as? String),
               !title.isEmpty {
                name = title
            }
            let state: ActivitySession.State
            var since: Date?
            if let sessionDir,
               let modified = (try? sessionDir.appendingPathComponent("updates.jsonl")
                    .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                state = now.timeIntervalSince(modified) <= Self.grokStaleAfter ? .working : .idle
                since = modified
            } else {
                state = .unknown
            }
            return ActivitySession(
                id: "grok-\(sid)",
                provider: .grok,
                name: String(name.prefix(100)),
                project: project,
                state: state,
                waitingReason: nil,
                since: since
            )
        }
        return Self.prioritized(sessions)
    }

    /// The on-disk layout is `sessions/<percent-encoded-cwd>/<session-id>/`. The encoding is
    /// Grok's own and has varied, so both forms are tried before falling back to the session id.
    static func grokSessionDirectory(id: String, cwd: String, under root: URL) -> URL? {
        var permissive = CharacterSet.alphanumerics
        permissive.insert(charactersIn: "-._~")
        let encodings = [cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                         cwd.addingPercentEncoding(withAllowedCharacters: permissive)].compactMap { $0 }
        for encoded in encodings {
            let candidate = root.appendingPathComponent(encoded).appendingPathComponent(id)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                          options: .skipsHiddenFiles) else { return nil }
        return folders.prefix(256).map { $0.appendingPathComponent(id) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `opened_at` is ISO 8601 in current builds; an epoch number is accepted in case that changes.
    private static func grokDate(_ raw: Any?) -> Date? {
        if let text = raw as? String { return GrokUsageParser.date(text) }
        if let seconds = (raw as? NSNumber)?.doubleValue, seconds.isFinite, seconds > 0 {
            return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        }
        return nil
    }

    /// Codex publishes no status field. The CLI and VS Code extension append to a thread's rollout
    /// log while a turn runs, and the desktop app updates its own thread catalogue; a write within
    /// this window is a turn in flight. It cannot tell thinking from a turn that ended a second
    /// ago, so it errs short, and the row is labeled as inferred.
    static let codexStaleAfter: TimeInterval = 8

    func readCodexSessions(codexHome: URL = ActivityReader.codexHome(), now: Date = .now) -> [ActivitySession] {
        var candidates: [(id: String, name: String, at: Date)] = []
        if let rollout = Self.newestCodexRollout(in: codexHome),
           let modified = (try? rollout.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            candidates.append(("codex-\(rollout.lastPathComponent)", "Codex", modified))
        }
        if let thread = Self.newestCodexDesktopThread(in: codexHome.appendingPathComponent("sqlite/codex-dev.db")) {
            candidates.append(("codex-desktop", thread.title, thread.updatedAt))
        }
        guard let newest = candidates.max(by: { $0.at < $1.at }),
              now.timeIntervalSince(newest.at) <= Self.codexStaleAfter else { return [] }
        return [ActivitySession(id: newest.id, provider: .codex, name: String(newest.name.prefix(100)), project: "Codex",
                                state: .working, waitingReason: nil, since: newest.at, isInferred: true)]
    }

    static func codexHome(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".codex")
    }

    /// The rollout of the most recently touched thread, from the newest `state_<n>.sqlite`.
    static func newestCodexRollout(in codexHome: URL) -> URL? {
        let stores = ((try? FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        for store in stores.prefix(4) {
            guard let db = ReadOnlySQLite.open(path: store.path) else { continue }
            defer { sqlite3_close(db) }
            let paths = ReadOnlySQLite.rows(in: db, sql: "SELECT rollout_path FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT 8", columns: 1)
            if let rollout = paths.compactMap({ $0.first }).map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                return rollout
            }
        }
        return nil
    }

    /// The desktop app (ChatGPT.app) writes none of the rollouts; it keeps its threads here.
    /// `source_updated_at` is seconds since the epoch with a fractional part.
    static func newestCodexDesktopThread(in url: URL) -> (title: String, updatedAt: Date)? {
        guard FileManager.default.fileExists(atPath: url.path), let db = ReadOnlySQLite.open(path: url.path) else { return nil }
        defer { sqlite3_close(db) }
        let rows = ReadOnlySQLite.rows(in: db, sql: "SELECT source_updated_at, display_title FROM local_thread_catalog ORDER BY source_updated_at DESC LIMIT 1", columns: 2)
        guard let row = rows.first, row.count == 2, let seconds = Double(row[0]), seconds.isFinite, seconds > 0 else { return nil }
        return (row[1].isEmpty ? "Codex" : row[1], Date(timeIntervalSince1970: seconds))
    }

    /// Antigravity appends to a trajectory's transcript as an agent runs, so a file written moments
    /// ago is a turn in progress. Step statuses cannot be used: every one says DONE, because a step
    /// is only written once it has finished. Generous, because a model can think for a while.
    static let antigravityStaleAfter: TimeInterval = 45

    static func antigravityTranscriptRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".gemini/antigravity/brain")
    }

    func readAntigravitySessions(root: URL = ActivityReader.antigravityTranscriptRoot(), now: Date = .now) -> [ActivitySession] {
        guard let trajectories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                              options: .skipsHiddenFiles) else { return [] }
        var newest: (id: String, modified: Date)?
        for trajectory in trajectories.prefix(256) {
            let transcript = trajectory.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard let modified = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (trajectory.lastPathComponent, modified)
            }
        }
        guard let newest, now.timeIntervalSince(newest.modified) <= Self.antigravityStaleAfter else { return [] }
        return [ActivitySession(id: "antigravity-\(newest.id)", provider: .antigravity, name: "Antigravity", project: "Antigravity",
                                state: .working, waitingReason: nil, since: newest.modified, isInferred: true)]
    }

    static func prioritized(_ sessions: [ActivitySession]) -> [ActivitySession] {
        let ranks: [ActivitySession.State: Int] = [.waiting: 0, .working: 1, .unknown: 2, .idle: 3]
        return sessions.sorted {
            let left = ranks[$0.state, default: 3], right = ranks[$1.state, default: 3]
            return left == right ? $0.id < $1.id : left < right
        }
    }

    private static func processStart(_ pid: Int32) -> Date? {
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, u_int(query.count), &process, &size, nil, 0) == 0, size > 0 else { return nil }
        let stamp = process.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(stamp.tv_sec) + Double(stamp.tv_usec) / 1_000_000)
    }
}

/// Read-only connections cannot create WAL sidecars, so opening a WAL database whose writer has
/// closed logs "unable to open database file". Without a `-wal` file no frames are pending, so the
/// main file is read immutably; with one present the WAL is honored for recent writes.
enum ReadOnlySQLite {
    static func open(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status: Int32
        if FileManager.default.fileExists(atPath: path + "-wal") {
            status = sqlite3_open_v2(path, &db, flags, nil)
        } else {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            status = sqlite3_open_v2("file:\(encoded)?immutable=1", &db, flags | SQLITE_OPEN_URI, nil)
        }
        guard status == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 100)
        return db
    }

    /// Every column of every row as text, for one-shot reads of another app's tables.
    static func rows(in db: OpaquePointer, sql: String, columns: Int) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW, rows.count < 256 {
            rows.append((0..<Int32(columns)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return rows
    }
}

/// `unfinishedRunAt` is a flag whose date can be the chat's creation date. Recent writes,
/// together with the editor's lifetime, are the evidence that an unfinished run is still working.
enum CursorActivityParser {
    static func session(from data: Data, launchedAt: Date?, now: Date = .now,
                        staleAfter: TimeInterval = 15 * 60) -> ActivitySession? {
        guard let launchedAt,
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = row["composerId"] as? String, !id.isEmpty else { return nil }
        let blocked = row["hasBlockingPendingActions"] as? Bool == true || row["hasPendingPlan"] as? Bool == true
        let run = date(row["unfinishedRunAt"])
        let touched = date(row["conversationCheckpointLastUpdatedAt"]) ?? date(row["lastUpdatedAt"]) ?? run
        let working = run != nil && touched.map {
            $0 >= launchedAt && $0 <= now.addingTimeInterval(5) && now.timeIntervalSince($0) <= staleAfter
        } == true
        guard blocked || working else { return nil }
        // `unfinishedRunAt` is the chat's creation time, so it dates a working row from when the
        // chat began; a row that is merely waiting must not borrow it.
        let since = (working && !blocked ? run : nil) ?? touched ?? date(row["createdAt"])
        return ActivitySession(id: "cursor-\(id)", provider: .cursor,
                               name: String((row["name"] as? String ?? "Untitled chat").prefix(100)),
                               project: String((row["subtitle"] as? String ?? "Cursor").prefix(160)),
                               state: blocked ? .waiting : .working,
                               waitingReason: blocked ? "Needs your input" : nil,
                               since: since)
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let millis = (raw as? NSNumber)?.doubleValue, millis.isFinite,
              millis > 0, millis < 253_402_300_800_000 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
