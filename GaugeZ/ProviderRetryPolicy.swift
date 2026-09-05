import Foundation

struct ProviderRetryError: LocalizedError, ProviderHealthDescribing {
    let until: Date
    var errorDescription: String? { "Rate limited. Next retry at \(until.formatted(date: .omitted, time: .standard))." }
    var providerHealth: ProviderHealth { .stale(errorDescription!) }
}

/// Only the retry deadline and attempt count are persisted, never account data.
struct ProviderRetryPolicy {
    let provider: ProviderID
    private var prefix: String { "retry.\(provider.rawValue)" }

    var deadline: Date? {
        guard let date = UserDefaults.standard.object(forKey: prefix + ".until") as? Date,
              date > .now else { return nil }
        return date
    }

    func check() throws {
        if let deadline { throw ProviderRetryError(until: deadline) }
    }

    func succeeded() { reset() }

    /// Clears the deadline and backoff so a user action (forget, disable, source switch) can always refresh.
    func reset() {
        UserDefaults.standard.removeObject(forKey: prefix + ".until")
        UserDefaults.standard.removeObject(forKey: prefix + ".attempts")
    }

    /// A server-supplied Retry-After is honored only up to this bound so one bad header cannot wedge a provider.
    static let maximumDelay: TimeInterval = 900

    func throttled(response: HTTPURLResponse) -> ProviderRetryError {
        let attempt = min(10, max(0, UserDefaults.standard.integer(forKey: prefix + ".attempts")))
        let floor = min(Self.maximumDelay, 60 * pow(2, Double(attempt)))
        var delay = floor
        if let raw = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(raw), seconds.isFinite {
                delay = max(floor, min(Self.maximumDelay, seconds))
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: raw) {
                    delay = max(floor, min(Self.maximumDelay, date.timeIntervalSinceNow))
                }
            }
        }
        let until = Date().addingTimeInterval(delay)
        UserDefaults.standard.set(until, forKey: prefix + ".until")
        UserDefaults.standard.set(attempt + 1, forKey: prefix + ".attempts")
        return ProviderRetryError(until: until)
    }
}
