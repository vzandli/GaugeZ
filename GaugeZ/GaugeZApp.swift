import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    let updateManager = UpdateManager()

    private var edgePanelController: EdgePanelController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var usageWindow: NSWindow?
    private var settingsObserver: NSObjectProtocol?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let panelController = EdgePanelController(store: store)
        edgePanelController = panelController
        panelController.show()
        configureStatusItem()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .gaugezOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.openSettings() }
        }
        store.refresh()
        if !UserDefaults.standard.bool(forKey: "hasSeenIntroduction") {
            openSettingsWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItem = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    @objc private func toggleNotch() {
        edgePanelController?.toggleVisibility()
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
    private func debugSnapshot(of window: NSWindow) {
        guard let directory = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_SNAPSHOTS"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-window.png"))
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

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Show GaugeZ", action: #selector(toggleNotch), keyEquivalent: "")
        menu.addItem(withTitle: "Usage…", action: #selector(openUsage), keyEquivalent: "u")
        menu.addItem(withTitle: "Refresh Usage", action: #selector(refreshUsage), keyEquivalent: "r")
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
        item.menu = menu
        statusItem = item

        // Status-item shortcuts alone only work while that menu is open. A main menu
        // makes Usage, Refresh, Settings, and Quit reachable in the regular windows.
        let mainMenu = NSMenu()
        let appMenu = NSMenuItem(title: "GaugeZ", action: nil, keyEquivalent: "")
        appMenu.submenu = menu.copy() as? NSMenu
        mainMenu.addItem(appMenu)
        NSApp.mainMenu = mainMenu
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
        if let toggleItem = menu.items.first {
            let isExpanded = edgePanelController?.isExpanded ?? false
            toggleItem.title = isExpanded ? "Hide GaugeZ" : "Show GaugeZ"
        }
        for item in menu.items {
            item.image = nil
        }
    }
}
