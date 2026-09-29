import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateManager: ObservableObject {
    let updaterController: SPUStandardUpdaterController
    private let reminders = GentleUpdateReminders()
    private let outcomes = UpdateOutcomeReporter()

    /// What the last check actually found, so Settings can say so instead of going quiet.
    enum Outcome: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case found(String)
        case unreachable
        case failed

        var message: String? {
            switch self {
            case .idle: nil
            case .checking: String(localized: "Checking…", bundle: .language)
            case .upToDate(let date):
                String.localizedStringWithFormat(String(localized: "Up to date · checked %@", bundle: .language),
                                                 date.formatted(date: .omitted, time: .shortened))
            case .found(let version): String.localizedStringWithFormat(String(localized: "Version %@ is available", bundle: .language), version)
            case .unreachable: String(localized: "The update server could not be reached.", bundle: .language)
            case .failed: String(localized: "The update check failed.", bundle: .language)
            }
        }
    }

    @Published private(set) var outcome: Outcome = .idle
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

    /// The version the rail's update card was put off for with Later. It is not offered on
    /// the rail again; the red dot on the settings button keeps it in reach.
    @Published private(set) var deferredVersion: String? = UserDefaults.standard.string(forKey: "updateDeferredVersion")

    /// A pending update the rail should offer, not yet put off.
    var updateToOffer: String? {
        guard let version = pendingUpdateVersion, version != deferredVersion else { return nil }
        return version
    }

    func deferPendingUpdate() {
        deferredVersion = pendingUpdateVersion
        UserDefaults.standard.set(deferredVersion, forKey: "updateDeferredVersion")
    }

    /// Without a menu bar item there is nowhere quiet to announce an update, so Sparkle's own
    /// alert is allowed through instead.
    var hasMenuBarPresence = true {
        didSet { reminders.hasMenuBarPresence = hasMenuBarPresence }
    }

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: outcomes,
            userDriverDelegate: reminders
        )
        updaterController = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        reminders.onPendingUpdateChange = { [weak self] version in
            self?.pendingUpdateVersion = version
        }
        outcomes.onOutcome = { [weak self] outcome in self?.outcome = outcome }
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        if ProcessInfo.processInfo.environment["GAUGEZ_PREVIEW_DATA"] != "1" {
            controller.startUpdater()
        }
        // Debug aid: GAUGEZ_DEBUG_UPDATE=<version> pretends a scheduled check found one.
        if let version = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_UPDATE"] {
            pendingUpdateVersion = version
        }
    }

    var currentVersion: String {
        let marketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String.localizedStringWithFormat(String(localized: "Version %@ (%@)", bundle: .language), marketingVersion, build)
    }

    func checkForUpdates() {
        outcome = .checking
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

/// Turns the end of a Sparkle update cycle into an `UpdateManager.Outcome`.
private final class UpdateOutcomeReporter: NSObject, SPUUpdaterDelegate {
    var onOutcome: (@MainActor (UpdateManager.Outcome) -> Void)?
    private var foundVersion: String?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundVersion = item.displayVersionString
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let outcome: UpdateManager.Outcome
        let code = (error as NSError?).flatMap { $0.domain == SUSparkleErrorDomain ? $0.code : nil }
        if let foundVersion {
            outcome = .found(foundVersion)
        } else if error == nil || code == Int(SUError.noUpdateError.rawValue) {
            outcome = .upToDate(.now)
        } else if code == Int(SUError.installationCanceledError.rawValue) {
            outcome = .idle
        } else if code == Int(SUError.downloadError.rawValue) || code == Int(SUError.appcastError.rawValue) || (error as NSError?)?.domain == NSURLErrorDomain {
            outcome = .unreachable
        } else {
            outcome = .failed
        }
        foundVersion = nil
        DispatchQueue.main.async { [onOutcome] in MainActor.assumeIsolated { onOutcome?(outcome) } }
    }
}
