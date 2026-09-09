import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateManager: ObservableObject {
    let updaterController: SPUStandardUpdaterController
    private let reminders = GentleUpdateReminders()
    private var canCheckObservation: NSKeyValueObservation?

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @Published private(set) var canCheckForUpdates = false

    /// A scheduled update found while GaugeZ was in the background. It is surfaced in the menu
    /// bar instead of an alert nobody sees; choosing Check for Updates shows it immediately.
    @Published private(set) var pendingUpdateVersion: String?

    /// Without a menu bar item there is nowhere quiet to announce an update, so Sparkle's own
    /// alert is allowed through instead.
    var hasMenuBarPresence = true {
        didSet { reminders.hasMenuBarPresence = hasMenuBarPresence }
    }

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: reminders
        )
        updaterController = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        reminders.onPendingUpdateChange = { [weak self] version in
            self?.pendingUpdateVersion = version
        }
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        if ProcessInfo.processInfo.environment["GAUGEZ_PREVIEW_DATA"] != "1" {
            controller.startUpdater()
        }
    }

    var currentVersion: String {
        let marketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String.localizedStringWithFormat(String(localized: "Version %@ (%@)", bundle: .language), marketingVersion, build)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

/// Sparkle's gentle-reminder hooks for a menu bar app: a scheduled update is only shown as an
/// alert when GaugeZ already has focus. Otherwise it is recorded so the menu can point at it.
/// Sparkle calls these on the main thread.
private final class GentleUpdateReminders: NSObject, SPUStandardUserDriverDelegate {
    var onPendingUpdateChange: (@MainActor (String?) -> Void)?
    var hasMenuBarPresence = true

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus || !hasMenuBarPresence
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        notify(update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        notify(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        notify(nil)
    }

    private func notify(_ version: String?) {
        MainActor.assumeIsolated { onPendingUpdateChange?(version) }
    }
}
