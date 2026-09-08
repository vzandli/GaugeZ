import Foundation
import UserNotifications

struct ThresholdAlert: Equatable, Sendable {
    let provider: ProviderID
    let threshold: Int
    let windowLabel: String
    let remaining: Double
    let resetsAt: Date?
}

/// Highest crossing stays latched until a fresh reading falls below 80% used.
struct ThresholdNotifier {
    private var crossed: [ProviderID: Int] = [:]

    mutating func observe(_ snapshot: UsageSnapshot, muted: Bool = false) -> [ThresholdAlert] {
        guard snapshot.health == .live, let window = snapshot.headlineWindow,
              window.usedPercent.isFinite else { return [] }
        let level = window.remainingPercent <= 0 ? 100 : window.remainingPercent <= 20 ? 80 : 0
        let previous = crossed[snapshot.provider, default: 0]
        crossed[snapshot.provider] = level == 0 ? 0 : max(previous, level)
        guard !muted else { return [] }
        return [80, 100].filter { $0 > previous && $0 <= level }.map {
            ThresholdAlert(provider: snapshot.provider, threshold: $0, windowLabel: window.label,
                           remaining: window.remainingPercent, resetsAt: window.resetsAt)
        }
    }

    mutating func forget(_ provider: ProviderID) { crossed[provider] = nil }
}

@MainActor
final class ThresholdAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ThresholdAlerts()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    func cancel() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func deliver(_ alerts: [ThresholdAlert]) {
        guard !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let id = UUID()
        tasks[id] = Task {
            defer { tasks[id] = nil }
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            for alert in alerts {
                guard !Task.isCancelled else { return }
                let content = UNMutableNotificationContent()
                content.title = alert.threshold == 100 ? "\(alert.provider.displayName) limit reached" : "\(alert.provider.displayName): \(PercentCopy.text(alert.remaining))% left"
                content.body = alert.windowLabel + (alert.resetsAt.map { " · Resets \(ResetCopy.absolute($0))" } ?? "")
                content.threadIdentifier = alert.provider.rawValue
                try? await center.add(UNNotificationRequest(identifier: "\(alert.provider.rawValue).\(alert.threshold).\(UUID())", content: content, trigger: nil))
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
