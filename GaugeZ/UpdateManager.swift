import Combine
import Sparkle

@MainActor
final class UpdateManager: ObservableObject {
    let updaterController: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @Published private(set) var canCheckForUpdates = false

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: ProcessInfo.processInfo.environment["GAUGEZ_PREVIEW_DATA"] != "1",
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    var currentVersion: String {
        let marketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(marketingVersion) (\(build))"
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
