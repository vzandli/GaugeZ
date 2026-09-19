// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import Foundation

/// The turn lifecycle Codex writes into a rollout. `item_completed` is ignored on purpose:
/// commands and other child items emit it too. A turn is over only at `task_complete`.
enum CodexRollout {
    enum Turn: Equatable, Sendable {
        case started
        case completed
        /// Stopped by the user: over, but not a finish worth announcing.
        case aborted
    }

    /// Rollouts run to hundreds of megabytes, so the file is walked backwards in slices.
    private static let windowBytes: UInt64 = 256 * 1024
    /// A mid-turn rollout keeps its `task_started` arbitrarily far behind the writes streaming
    /// in; walking to it would read the whole file on every poll. Past a megabyte the search
    /// gives up and the caller falls back to write recency.
    private static let maxWindows = 4

    /// The newest lifecycle event, or nil when none is within reach of the end of the file.
    static func latestTurn(in url: URL) -> Turn? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var windowEnd = try? handle.seekToEnd() else { return nil }

        // A window's first line is cut in half by the read; the fragment is carried into the
        // earlier window, where the rest of it lives, rather than parsed as half a line.
        var carried = Data()
        var windows = 0
        while windowEnd > 0, windows < maxWindows {
            windows += 1
            let windowStart = windowEnd > windowBytes ? windowEnd - windowBytes : 0
            let length = Int(windowEnd - windowStart)
            guard (try? handle.seek(toOffset: windowStart)) != nil else { return nil }
            // `read(upToCount:)` may deliver less than asked; a short window would lose lines.
            var window = Data()
            window.reserveCapacity(length)
            while window.count < length {
                guard let chunk = try? handle.read(upToCount: length - window.count) else { return nil }
                if chunk.isEmpty { break }
                window.append(chunk)
            }
            // Only a window that reached `windowEnd` is contiguous with the carried fragment.
            if window.count == length { window.append(carried) }

            let startsOnLineBreak = window.first == UInt8(ascii: "\n")
            var lines = window.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            carried = windowStart > 0 && !startsOnLineBreak && !lines.isEmpty ? Data(lines.removeFirst()) : Data()

            for line in lines.reversed() {
                // Cheap reject before parsing: most lines are model output, not lifecycle events.
                guard line.count < 65_536,
                      let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      record["type"] as? String == "event_msg",
                      let payload = record["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { continue }
                switch type {
                case "task_started": return .started
                case "task_complete": return .completed
                case "turn_aborted": return .aborted
                default: continue
                }
            }
            windowEnd = windowStart
        }
        return nil
    }
}
