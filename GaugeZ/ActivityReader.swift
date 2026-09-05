import Foundation
import Darwin

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

    func readClaudeSessions() -> [ActivitySession] {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
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
            return ActivitySession(id: "claude-\(pid)", provider: .claude,
                                   name: String((record["name"] as? String ?? project).prefix(100)),
                                   project: project, state: state,
                                   waitingReason: (record["waitingFor"] as? String ?? record["needs"] as? String).map { String($0.prefix(160)) })
        }.sorted {
            let rank: [ActivitySession.State: Int] = [.waiting: 0, .working: 1, .unknown: 2, .idle: 3]
            if rank[$0.state] != rank[$1.state] { return rank[$0.state, default: 3] < rank[$1.state, default: 3] }
            return $0.id < $1.id
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
