import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    let updateManager = UpdateManager()

    private var edgePanelControllers: [EdgePanelController] = []
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var usageWindow: NSWindow?
    private var settingsObserver: NSObjectProtocol?
    private var whatsNew: WhatsNewWindowController?
    private var cancellables = Set<AnyCancellable>()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Applied here, not from the Info.plist alone: the user's presence choice can make this
        // a regular app with a Dock tile, and the call overrides `LSUIElement` either way.
        applyPresence(store.appPresence)
        store.$appPresence
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] presence in self?.applyPresence(presence) }
            .store(in: &cancellables)

        rebuildPanels()
        store.$selectedDisplayID.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildPanels() }.store(in: &cancellables)
        // Each controller already repositions itself on this notification. Tearing the panels
        // down is only needed when a display joins or leaves an all-displays setup; otherwise a
        // resolution change or display sleep would drop hover state and any pinned card.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.store.selectedDisplayID == "all",
                      self.panelDisplayIDs != Self.currentDisplayIDs else { return }
                self.rebuildPanels()
            }
            .store(in: &cancellables)
        configureMainMenu()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .gaugezOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.openSettings() }
        }
        store.refresh()
        if store.isPreview {
            // Debug aid: GAUGEZ_DEBUG_WHATSNEW=1 shows this version's notes in preview mode.
            if ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_WHATSNEW"] != nil,
               let note = ReleaseNotes.note(for: Self.marketingVersion) ?? ReleaseNotes.all.first {
                let controller = WhatsNewWindowController(version: note.version, defaults: UserDefaults(suiteName: "GaugeZ.preview")!)
                whatsNew = controller
                controller.showIfNeeded()
                if let window = NSApp.windows.first(where: { $0.title == "What's New in GaugeZ" }) { debugSnapshot(of: window, name: "whats-new") }
            }
            return
        }

        // What changed, once per version. A fresh install gets the introduction instead, and is
        // recorded as having seen this version so the notes do not appear on its second launch.
        let whatsNew = WhatsNewWindowController(version: Self.marketingVersion)
        self.whatsNew = whatsNew
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasSeenIntroduction") && whatsNew.lastSeenVersion == nil
        if firstLaunch {
            whatsNew.markSeen()
            openSettingsWindow()
        } else if !whatsNew.showIfNeeded(), !UserDefaults.standard.bool(forKey: "hasSeenIntroduction") {
            openSettingsWindow()
        }
    }

    /// The displays the current panels were built for, so a screen-parameter change that
    /// leaves the set unchanged does not rebuild anything.
    private var panelDisplayIDs: Set<String> = []

    private static var currentDisplayIDs: Set<String> {
        Set(NSScreen.screens.map { DisplayChoice.identifier(for: $0) })
    }

    private func rebuildPanels() {
        for panel in edgePanelControllers { panel.close() }
        panelDisplayIDs = Self.currentDisplayIDs
        let ids: [String?] = store.selectedDisplayID == "all"
            ? NSScreen.screens.map { DisplayChoice.identifier(for: $0) } : [nil]
        edgePanelControllers = ids.map { EdgePanelController(store: store, displayID: $0) }
        for panel in edgePanelControllers { panel.show() }
    }

    @objc private func refreshProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = ProviderID(rawValue: raw) else { return }
        store.retry(provider)
    }

    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Closing Settings must not take the rail with it, which is the default for a Dock app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The way back in when there is no Dock tile and no menu bar item: opening GaugeZ again
    /// from Applications or Spotlight while it is running lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    private func applyPresence(_ presence: AppPresence) {
        NSApp.setActivationPolicy(presence.activationPolicy)
        if presence.wantsStatusItem {
            if statusItem == nil { configureStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        updateManager.hasMenuBarPresence = presence.wantsStatusItem
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItem = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    @objc private func toggleNotch() {
        let expand = !edgePanelControllers.contains(where: \.isExpanded)
        for panel in edgePanelControllers { panel.setVisibility(expand) }
    }

    @objc private func refreshUsage() {
        store.refresh()
    }

    @objc private func checkForUpdates() {
        updateManager.checkForUpdates()
    }

    /// The SwiftUI Settings scene can only be opened from a SettingsLink, so GaugeZ hosts its
    /// settings in an ordinary window it can open from the menu bar and the edge panel.
    @objc func openSettings() {
        openSettingsWindow()
    }

    @objc func openSettingsWindow() {
        store.updateSystemSettings()
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.center()
        present(window)
        debugSnapshot(of: window)
    }

    /// Brings one of GaugeZ's windows in front of every other app's windows. As an accessory
    /// (menu bar) app the process is rarely active, and since macOS 14 activation is cooperative:
    /// `makeKeyAndOrderFront` alone leaves the window behind the previously active app. Activate
    /// first, handing focus over from the current front app, then order the window in regardless.
    private func present(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        if #available(macOS 14.0, *) {
            if let front = NSWorkspace.shared.frontmostApplication, front != .current {
                NSRunningApplication.current.activate(from: front, options: [.activateIgnoringOtherApps])
            } else {
                NSApp.activate()
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Debug aid: with GAUGEZ_DEBUG_SNAPSHOTS set, renders the settings window to a PNG.
    private func debugSnapshot(of window: NSWindow, name: String = "settings-window") {
        guard let directory = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_SNAPSHOTS"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    @objc private func openUsage() {
        let window = usageWindow ?? NSWindow(contentViewController: NSHostingController(rootView: UsageOverviewView(store: store)))
        usageWindow = window
        window.title = "GaugeZ Usage"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 440, height: 620))
        window.center()
        present(window)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(store: store, updateManager: updateManager))
        let window = NSWindow(contentViewController: hosting)
        window.title = "GaugeZ Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 640))
        window.minSize = NSSize(width: 760, height: 540)
        window.backgroundColor = NSColor(red: 0.048, green: 0.055, blue: 0.071, alpha: 1)
        return window
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: "GaugeZMenuBar")
                ?? NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "GaugeZ")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imageScaling = .scaleProportionallyDown
        }
        item.menu = makeMenu()
        statusItem = item
    }

    /// Status-item shortcuts alone only work while that menu is open. A main menu makes Usage,
    /// Refresh, Settings, and Quit reachable in the regular windows, and is the app menu when
    /// GaugeZ shows a Dock tile.
    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenuItem(title: "GaugeZ", action: nil, keyEquivalent: "")
        appMenu.submenu = makeMenu()
        mainMenu.addItem(appMenu)
        NSApp.mainMenu = mainMenu
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Show GaugeZ", action: #selector(toggleNotch), keyEquivalent: "")
        menu.addItem(withTitle: "Usage…", action: #selector(openUsage), keyEquivalent: "u")
        menu.addItem(withTitle: "Refresh Usage", action: #selector(refreshUsage), keyEquivalent: "r")
        let providers = NSMenuItem(title: "Refresh Provider", action: nil, keyEquivalent: "")
        providers.submenu = NSMenu()
        menu.addItem(providers)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        let settingsItem = menu.addItem(withTitle: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.image = nil
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GaugeZ", action: #selector(quit), keyEquivalent: "q")

        for menuItem in menu.items {
            menuItem.target = self
            menuItem.image = nil
        }
        return menu
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        syncMenuState(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        syncMenuState(menu)
    }

    private func syncMenuState(_ menu: NSMenu) {
        if let submenu = menu.items.first(where: { $0.title == "Refresh Provider" })?.submenu {
            submenu.removeAllItems()
            for provider in store.visibleProviders {
                let item = submenu.addItem(withTitle: provider.displayName, action: #selector(refreshProvider(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = provider.rawValue
                item.isEnabled = !store.refreshing.contains(provider) && store.nextRetry(for: provider) == nil
            }
            submenu.autoenablesItems = false
        }
        if let toggleItem = menu.items.first {
            let isExpanded = edgePanelControllers.contains(where: \.isExpanded)
            toggleItem.title = isExpanded ? "Hide GaugeZ" : "Show GaugeZ"
        }
        if let updateItem = menu.items.first(where: { $0.action == #selector(checkForUpdates) }) {
            updateItem.title = updateManager.pendingUpdateVersion.map { "Update to \($0) Available…" } ?? "Check for Updates…"
        }
        for item in menu.items {
            item.image = nil
        }
    }
}
