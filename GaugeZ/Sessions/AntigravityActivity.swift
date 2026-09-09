import Foundation

/// How much Antigravity has actually been used, counted from its own
/// transcripts.
///
/// When quota cannot be read, this is a count without an invented denominator.
/// Only source and timestamp fields are decoded; conversation text is never retained.
struct AntigravityActivity: Equatable {
    let requestsToday: Int
    let lastRequest: Date?

    static var transcriptRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/antigravity/brain")
    }

    /// A step the model actually answered. User input and system checkpoints
    /// share the transcript, and counting those would inflate the number with
    /// work the model never did.
    private static let modelSource = "MODEL"

    static func read(root: URL = transcriptRoot, now: Date = Date()) -> AntigravityActivity {
        let manager = FileManager.default
        guard let trajectories = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return AntigravityActivity(requestsToday: 0, lastRequest: nil) }

        var today = 0
        var latest: Date?
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func consume(_ data: Data) {
            guard let step = try? decoder.decode(Step.self, from: data), step.source == modelSource,
                  let at = plain.date(from: step.created_at) ?? fractional.date(from: step.created_at), at <= now else { return }
            if latest == nil || at > latest! { latest = at }
            if calendar.isDate(at, inSameDayAs: now) { today += 1 }
        }
        for trajectory in trajectories {
            if Task.isCancelled { break }
            let transcript = trajectory.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard let handle = try? FileHandle(forReadingFrom: transcript) else { continue }
            defer { try? handle.close() }
            var pending = Data()
            var skippingOversizedLine = false
            while !Task.isCancelled, let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    if !skippingOversizedLine { consume(Data(pending[..<end])) }
                    skippingOversizedLine = false
                    pending.removeSubrange(...end)
                }
                // Malformed or enormous text records must not consume unbounded memory.
                if pending.count > 4_000_000 { pending.removeAll(); skippingOversizedLine = true }
            }
            if !skippingOversizedLine, !pending.isEmpty { consume(pending) }
        }
        return AntigravityActivity(requestsToday: today, lastRequest: latest)
    }

    private struct Step: Decodable {
        let created_at: String
        let source: String?
    }

    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    /// What the cell says. Deliberately a count with the limit's absence stated,
    /// rather than a number that looks like a percentage.
    var summary: String {
        guard requestsToday > 0 else { return String(localized: "no requests today", bundle: .language) }
        return String(localized: "~\(Int(requestsToday)) requests today", bundle: .language)
    }
}
