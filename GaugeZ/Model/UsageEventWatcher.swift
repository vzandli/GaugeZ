import Foundation

/// What a limit window did between two live readings: it filled up, or it rolled over.
enum UsageEventKind: Equatable, Sendable {
    /// The window hit zero remaining — the moment a limit actually bites.
    case limitReached
    /// The window rolled over and quota is back.
    case limitReset
}

struct UsageEvent: Equatable, Sendable {
    let provider: ProviderID
    let kind: UsageEventKind
    /// The window the event is about.
    let window: UsageWindow
}

/// Difference engine over consecutive live readings: announces the transitions between
/// them — a window reaching zero, or a used window rolling over to fresh quota — once
/// per transition.
///
/// The first reading only seeds state, exactly like the session completion watcher:
/// every provider already burning quota at launch would otherwise announce itself, and
/// a snapshot restored from the cache is stale, not news. Muted providers keep being
/// tracked, so unmuting never replays transitions that happened while muted.
struct UsageEventWatcher {
    private struct Tracked {
        var exhausted: Bool
        /// The fullest this window has been seen, as used — a reset is only announced
        /// for a window that was actually worked in.
        var usedPeak: Double
        var resetsAt: Date?
        var remaining: Double
    }

    private var states: [String: Tracked] = [:]

    /// A window that never saw 15% used has nothing to reset.
    static let significantUse: Double = 15
    /// How far `resetsAt` may slide between readings before the move reads as a rollover.
    /// A real rollover pushes the date out by the whole window length, not by minutes.
    static let rolloverSlack: TimeInterval = 300
    /// A remaining rise this large between readings is a fresh window when the provider
    /// reports no reset time at all.
    static let refillJump: Double = 20
    /// Exhaustion clears only once the reading climbs clear of the floor, so a window
    /// jittering between 0.0% and 0.1% remaining is one crossing, not a metronome.
    static let exhaustionHysteresis: Double = 5

    mutating func observe(_ snapshot: UsageSnapshot, muted: Bool = false) -> [UsageEvent] {
        guard snapshot.health == .live else { return [] }
        var events: [UsageEvent] = []
        for window in snapshot.windows {
            let used = window.usedPercent
            guard used.isFinite else { continue }
            let key = snapshot.provider.rawValue + "\u{1}" + window.id
            let remaining = window.remainingPercent
            guard let previous = states[key] else {
                states[key] = Tracked(exhausted: window.isExhausted, usedPeak: used,
                                      resetsAt: window.resetsAt, remaining: remaining)
                continue
            }

            var exhausted = previous.exhausted
            if window.isExhausted {
                exhausted = true
            } else if remaining > Self.exhaustionHysteresis {
                exhausted = false
            }

            // A rollover is a reset time shoved out by more than a slide, or — only when
            // no reset time is reported on either side — remaining leaping back up. Both
            // count solely for a window the account actually used, and only land on a
            // reading that is mostly fresh.
            var rolled = false
            if previous.usedPeak >= Self.significantUse, remaining >= 50 {
                if let previousReset = previous.resetsAt, let reset = window.resetsAt {
                    rolled = reset.timeIntervalSince(previousReset) > Self.rolloverSlack
                } else if remaining - previous.remaining >= Self.refillJump {
                    rolled = true
                }
            }

            // The fresh window starts its own peak: a window used once and then left idle
            // has nothing to reset the next time round.
            states[key] = Tracked(exhausted: exhausted, usedPeak: rolled ? used : max(previous.usedPeak, used),
                                  resetsAt: window.resetsAt, remaining: remaining)
            guard !muted else { continue }
            if window.isExhausted, !previous.exhausted {
                events.append(UsageEvent(provider: snapshot.provider, kind: .limitReached, window: window))
            }
            if rolled {
                events.append(UsageEvent(provider: snapshot.provider, kind: .limitReset, window: window))
            }
        }
        return events
    }

    /// A provider switched off or forgotten starts over when it comes back: the first
    /// reading after that seeds again, and announces nothing.
    mutating func forget(_ provider: ProviderID) {
        let prefix = provider.rawValue + "\u{1}"
        states = states.filter { !$0.key.hasPrefix(prefix) }
    }
}
