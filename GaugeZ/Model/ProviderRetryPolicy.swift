import Foundation

struct ProviderRetryError: LocalizedError, ProviderHealthDescribing {
    let until: Date
    var errorDescription: String? { String(localized: "Rate limited. Next retry at \(until.formatted(date: .omitted, time: .standard)).", bundle: .language) }
    var providerHealth: ProviderHealth { .stale(errorDescription!) }
}

/// Only the retry deadline and attempt count are persisted, never account data.
struct ProviderRetryPolicy {
    let provider: ProviderID
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(provider: ProviderID, defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { .now }) {
        self.provider = provider
        self.defaults = defaults
        self.now = now
    }

    private var prefix: String { "retry.\(provider.rawValue)" }

    var deadline: Date? {
        guard let date = defaults.object(forKey: prefix + ".until") as? Date,
              date > now() else { return nil }
        return date
    }

    func check() throws {
        if let deadline { throw ProviderRetryError(until: deadline) }
    }

    func succeeded() { reset() }

    /// Clears the deadline and backoff so a user action (forget, disable, source switch) can always refresh.
    func reset() {
        defaults.removeObject(forKey: prefix + ".until")
        defaults.removeObject(forKey: prefix + ".attempts")
    }

    /// A server-supplied Retry-After is honored only up to this bound so one bad header cannot wedge a provider.
    static let maximumDelay: TimeInterval = 900

    func throttled(response: HTTPURLResponse) -> ProviderRetryError {
        var retryAfter: TimeInterval?
        if let raw = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(raw), seconds.isFinite {
                retryAfter = seconds
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: raw) {
                    retryAfter = date.timeIntervalSince(now())
                }
            }
        }
        return throttled(retryAfter: retryAfter)
    }

    /// For sources that report throttling without an HTTP response (a local app-server relaying a
    /// 429, or an error envelope inside a 200): the same exponential floor, optionally raised by
    /// a server-supplied wait.
    func throttled(retryAfter: TimeInterval?) -> ProviderRetryError {
        let attempt = min(10, max(0, defaults.integer(forKey: prefix + ".attempts")))
        let floor = min(Self.maximumDelay, 60 * pow(2, Double(attempt)))
        var delay = floor
        if let retryAfter, retryAfter.isFinite {
            delay = max(floor, min(Self.maximumDelay, retryAfter))
        }
        let until = now().addingTimeInterval(delay)
        defaults.set(until, forKey: prefix + ".until")
        defaults.set(attempt + 1, forKey: prefix + ".attempts")
        return ProviderRetryError(until: until)
    }
}
