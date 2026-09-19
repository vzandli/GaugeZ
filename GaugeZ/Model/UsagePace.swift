// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import Foundation

/// Quota spent against time elapsed in the same window: burning 60% of a limit a third of the
/// way through it is a different fact from burning it on the last day.
struct UsagePace: Equatable, Sendable {
    /// Used quota minus elapsed time, in percentage points. Positive is spending too fast.
    let percentagePoints: Double

    var isOver: Bool { percentagePoints > 0 }

    var summary: String {
        let value = PercentCopy.text(abs(percentagePoints))
        return isOver
            ? String.localizedStringWithFormat(String(localized: "%@%% over pace", bundle: .language), value)
            : String.localizedStringWithFormat(String(localized: "%@%% under pace", bundle: .language), value)
    }
}

extension UsageWindow {
    /// Nil without a length and a future reset: there is no clock to compare against.
    func pace(now: Date = .now) -> UsagePace? {
        guard usedPercent.isFinite, usedPercent >= 0,
              let durationMinutes, durationMinutes > 0, let resetsAt else { return nil }
        let remainingTime = resetsAt.timeIntervalSince(now)
        guard remainingTime > 0 else { return nil }
        // Provider and device clocks can put a fresh reset just beyond one full cycle.
        let elapsed = 1 - min(remainingTime / (Double(durationMinutes) * 60), 1)
        return UsagePace(percentagePoints: min(usedPercent, 100) - elapsed * 100)
    }
}

/// A day's share of Claude's weekly allowance as a window of its own. The weekly limit is the
/// one that runs out, and the way to make it last is to spend about a seventh of it a day: the
/// share available so far is `(days elapsed + 1) / 7`, counted from the moment the weekly window
/// opened, and the ring is what has been used against it. At 100% the ordinary alerts fire.
enum DailyPace {
    /// Never an id a provider reports.
    static let windowID = "daily_pace"
    static let weeklyID = "seven_day"
    private static let dayLength: TimeInterval = 86_400
    private static let days = 7

    /// No `durationMinutes`, on purpose: a window that *is* a pace has nothing to be paced against.
    static func window(weekly: UsageWindow, now: Date) -> UsageWindow? {
        guard weekly.usedPercent.isFinite, weekly.usedPercent >= 0, let resetsAt = weekly.resetsAt else { return nil }
        let weekLength = Double(days) * dayLength
        let start = resetsAt.addingTimeInterval(-weekLength)
        // Clocks can disagree a little either way; neither a negative day nor an eighth is real.
        let elapsed = min(max(now.timeIntervalSince(start), 0), weekLength)
        let dayIndex = min(days - 1, Int(elapsed / dayLength))
        let allowed = Double(dayIndex + 1) / Double(days)
        let dayEnds = dayIndex == days - 1 ? resetsAt : start.addingTimeInterval(Double(dayIndex + 1) * dayLength)
        return UsageWindow(id: windowID, label: String(localized: "Daily pace", bundle: .language),
                           usedPercent: min(100, weekly.usedPercent / allowed), resetsAt: dayEnds, durationMinutes: nil)
    }

    /// Leads a Claude snapshot with the daily window and makes it the headline. Anything without
    /// a weekly reading comes back untouched.
    static func apply(to snapshot: UsageSnapshot, now: Date = .now) -> UsageSnapshot {
        guard snapshot.provider.kind == .claude,
              !snapshot.windows.contains(where: { $0.id == windowID }),
              let weekly = snapshot.windows.first(where: { $0.id == weeklyID }),
              let daily = window(weekly: weekly, now: now) else { return snapshot }
        var paced = UsageSnapshot(
            provider: snapshot.provider, accountID: snapshot.accountID, planName: snapshot.planName,
            windows: [daily] + snapshot.windows, observedAt: snapshot.observedAt, source: snapshot.source,
            health: snapshot.health, costInfo: snapshot.costInfo, headlineWindowID: windowID,
            derivedRequestCount: snapshot.derivedRequestCount, resetCredits: snapshot.resetCredits)
        paced.dailyTokens = snapshot.dailyTokens
        return paced
    }
}
