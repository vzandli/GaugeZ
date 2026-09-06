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
            return ActivitySession(id: "\(profile.provider.rawValue)-\(pid)", provider: profile.provider,
                                   name: String((record["name"] as? String ?? project).prefix(100)),
                                   project: project, state: state,
                                   waitingReason: (record["waitingFor"] as? String ?? record["needs"] as? String).map { String($0.prefix(160)) })
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

    func readGrokSessions() -> [ActivitySession] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let activeURL = home.appendingPathComponent(".grok/active_sessions.json")
        guard let data = try? Data(contentsOf: activeURL),
              let active = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        let sessions: [ActivitySession] = active.prefix(16).compactMap { item in
            guard let sid = item["session_id"] as? String,
                  let pidNum = item["pid"] as? NSNumber,
                  let cwd = item["cwd"] as? String else { return nil }
            let pid = pidNum.int32Value
            guard pid > 0, Self.processStart(pid) != nil else { return nil }

            let project = URL(fileURLWithPath: cwd).lastPathComponent
            let encodedCwd = cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cwd
            let sessionDir = home.appendingPathComponent(".grok/sessions").appendingPathComponent(encodedCwd).appendingPathComponent(sid)
            var name = project
            if let summaryData = try? Data(contentsOf: sessionDir.appendingPathComponent("summary.json")),
               let summary = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any],
               let title = (summary["session_summary"] as? String ?? summary["generated_title"] as? String),
               !title.isEmpty {
                name = title
            }
            return ActivitySession(
                id: "grok-\(sid)",
                provider: .grok,
                name: String(name.prefix(100)),
                project: project,
                state: .working,
                waitingReason: nil
            )
        }
        return Self.prioritized(sessions)
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
        return ActivitySession(id: "cursor-\(id)", provider: .cursor,
                               name: String((row["name"] as? String ?? "Untitled chat").prefix(100)),
                               project: String((row["subtitle"] as? String ?? "Cursor").prefix(160)),
                               state: blocked ? .waiting : .working,
                               waitingReason: blocked ? "Needs your input" : nil)
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let millis = (raw as? NSNumber)?.doubleValue, millis.isFinite,
              millis > 0, millis < 253_402_300_800_000 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
