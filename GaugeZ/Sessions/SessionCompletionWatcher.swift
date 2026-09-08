import Foundation

/// Transitions only: initial, missing, unknown, and newly discovered sessions stay quiet.
struct SessionCompletionWatcher {
    enum Reason: Equatable, Sendable { case finished, blocked }
    struct Event: Equatable, Sendable {
        let session: ActivitySession
        let reason: Reason
    }
    private var previous: [String: ActivitySession.State] = [:]

    mutating func absorb(_ sessions: [ActivitySession]) -> [Event] {
        var current: [String: ActivitySession.State] = [:]
        var events: [Event] = []
        for session in sessions {
            let key = session.provider.rawValue + "\u{1}" + session.id
            current[key] = session.state
            guard previous[key] == .working else { continue }
            if session.state == .idle { events.append(Event(session: session, reason: .finished)) }
            if session.state == .waiting { events.append(Event(session: session, reason: .blocked)) }
        }
        previous = current
        return events.sorted { ($0.session.since ?? .distantPast) > ($1.session.since ?? .distantPast) }
    }
}
