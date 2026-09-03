import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Owns the borderless edge panel and the hover state machine:
/// collapsed tab -> expanded rail -> anchored detail card / attached settings.
@MainActor
final class EdgePanelController {
    private let store: UsageStore
    private let panel: EdgePanel
    private let state = EdgePanelState()
    private var cancellables = Set<AnyCancellable>()
    private var collapseTask: Task<Void, Never>?
    private var attachmentTask: Task<Void, Never>?
    private var isPointerInRail = false
    private var isPointerInAttachment = false
    private var isAttachmentPinned = false
    private var pointerMonitors: [Any] = []
    /// Pointer position when the window moved away from under it; see `routePointer`.
    private var pendingCollapseOrigin: NSPoint?

    /// Debug aid: GAUGEZ_DEBUG_LOG=<file> mirrors hover events to a file.
    private func debugNote(_ message: String) {
        guard let path = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_LOG"] else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) panel: \(message)\n"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// Debug aid: GAUGEZ_DEBUG_SNAPSHOTS=<dir> writes a PNG of the panel after each state change.
    private static let snapshotDirectory = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_SNAPSHOTS"]
    private var snapshotCounter = 0
    private var snapshotTask: Task<Void, Never>?

    init(store: UsageStore) {
        self.store = store
        panel = EdgePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        installContent()
        observeSettings()
        installPointerMonitors()
        applyDisplayMode(animated: false)
        runDemoIfRequested()
    }

    deinit {
        for monitor in pointerMonitors {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Pointer routing

    /// The window is a constant-size transparent panel, and a transparent window still swallows
    /// clicks. So the window only accepts mouse events while the pointer is over drawn content,
    /// and passes everything through otherwise; a global monitor watches the pointer meanwhile.
    private func installPointerMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            Task { @MainActor in self?.routePointer() }
        }) {
            pointerMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.routePointer()
            return event
        }) {
            pointerMonitors.append(monitor)
        }
        panel.ignoresMouseEvents = true
    }

    private func routePointer() {
        let location = NSEvent.mouseLocation
        let over = interactiveRects.contains { $0.contains(location) }
        if panel.ignoresMouseEvents == over {
            panel.ignoresMouseEvents = !over
            debugNote("pointer \(over ? "over" : "off") content at \(Int(location.x)),\(Int(location.y)) rects \(interactiveRects.map { "\(Int($0.minX))-\(Int($0.maxX))" })")
        }
        // After the window itself moved (edge switch) the rail slid out from under the pointer
        // without a hover-exit event. Keep what was open until the pointer clearly moves away.
        if let origin = pendingCollapseOrigin {
            if over {
                pendingCollapseOrigin = nil
            } else if hypot(location.x - origin.x, location.y - origin.y) > 40 {
                pendingCollapseOrigin = nil
                scheduleCollapse()
            }
        }
    }

    /// Screen rects of the drawn, interactive parts: the rail column and, when open, the card column.
    private var interactiveRects: [NSRect] {
        let frame = panel.frame
        let railWidth = state.isExpanded ? RailMetrics.expandedWidth : RailMetrics.collapsedWidth
        let railRect = store.edgeSide == .right
            ? NSRect(x: frame.maxX - railWidth, y: frame.minY, width: railWidth, height: frame.height)
            : NSRect(x: frame.minX, y: frame.minY, width: railWidth, height: frame.height)
        var rects = [railRect]
        if state.isExpanded, state.attachment != nil {
            let width = RailMetrics.attachmentWidth + RailMetrics.attachmentGap + RailMetrics.pointerDepth
            rects.append(store.edgeSide == .right
                ? NSRect(x: railRect.minX - width, y: frame.minY, width: width, height: frame.height)
                : NSRect(x: railRect.maxX, y: frame.minY, width: width, height: frame.height))
        }
        return rects
    }

    /// Debug aid: GAUGEZ_DEBUG_DEMO=1 walks through every panel state with no pointer input,
    /// so self-rendered snapshots can be reviewed without screen-recording permission.
    private func runDemoIfRequested() {
        guard ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_DEMO"] != nil else { return }
        Task { [weak self] in
            let step: Duration = .milliseconds(1100)
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.railHoverChanged(true)
            try? await Task.sleep(for: step)
            for provider in self.store.visibleProviders {
                self.providerHoverChanged(provider)
                try? await Task.sleep(for: step)
            }
            self.providerHoverChanged(nil)
            self.toggleSettings()
            try? await Task.sleep(for: step)
            self.toggleSettings()
            self.railHoverChanged(false)
            try? await Task.sleep(for: step)
            NotificationCenter.default.post(name: .gaugezOpenSettings, object: nil)
        }
    }

    var isExpanded: Bool {
        state.isExpanded
    }

    func show() {
        if store.displayMode == .hidden {
            store.displayMode = .hover
        }
        positionPanel(animated: false)
        panel.orderFrontRegardless()
    }

    func toggleVisibility() {
        if state.isExpanded {
            setExpanded(false)
        } else {
            if store.displayMode == .hidden {
                store.displayMode = .hover
            }
            positionPanel(animated: false)
            panel.orderFrontRegardless()
            setExpanded(true)
        }
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
    }

    private func installContent() {
        let actions = EdgePanelActions(
            railHover: { [weak self] inside in self?.railHoverChanged(inside) },
            providerHover: { [weak self] provider in self?.providerHoverChanged(provider) },
            providerSelect: { [weak self] provider in self?.providerSelected(provider) },
            settingsToggle: { [weak self] in self?.toggleSettings() },
            attachmentHover: { [weak self] inside in self?.attachmentHoverChanged(inside) },
            gearZoneHover: { [weak self] _ in self?.scheduleDebugSnapshot() }
        )
        let root = EdgePanelContentView(state: state, actions: actions).environmentObject(store)
        let view = NSHostingView(rootView: AnyView(root))
        // The content is a constant-width container wider than the collapsed window; the window
        // must keep the frame the controller sets and clip, not grow to fit the content.
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
    }

    /// `@Published` emits from `willSet`, so these sinks are deferred to the next main-queue
    /// turn; otherwise they would read the store's *previous* value and, for example, keep the
    /// window on the old edge after the side is switched.
    private func observeSettings() {
        store.$displayMode
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.applyDisplayMode(animated: true)
                }
            }
            .store(in: &cancellables)

        store.$edgeSide
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.edgeSideChanged()
                }
            }
            .store(in: &cancellables)

        store.$enabledProviders
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if case .detail(let provider) = self.state.attachment, !self.store.enabledProviders.contains(provider) {
                        self.setAttachment(nil)
                    }
                    self.positionPanel(animated: true)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.positionPanel(animated: false)
                }
            }
            .store(in: &cancellables)
    }

    /// Moves the window to the newly selected edge. The pointer is now far from the rail and no
    /// hover-exit event will arrive, so the hover flags are reset; an attachment the user opened
    /// (the settings they just used) stays pinned until the next pointer movement away from it.
    private func edgeSideChanged() {
        debugNote("edge -> \(store.edgeSide)")
        positionPanel(animated: true)
        routePointer()
        if state.isExpanded, !pointerIsOverVisibleContent {
            collapseTask?.cancel()
            isPointerInRail = false
            isPointerInAttachment = false
            pendingCollapseOrigin = NSEvent.mouseLocation
        }
    }

    // MARK: - Hover state machine

    private func railHoverChanged(_ inside: Bool) {
        debugNote("rail hover \(inside)")
        isPointerInRail = inside
        collapseTask?.cancel()
        guard store.displayMode == .hover else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if inside {
                self.pendingCollapseOrigin = nil
                self.setExpanded(true)
            } else if self.pendingCollapseOrigin == nil {
                // An exit caused by the window moving away (edge switch) is deferred to `routePointer`.
                self.scheduleCollapse()
            }
        }
    }

    private func attachmentHoverChanged(_ inside: Bool) {
        isPointerInAttachment = inside
        collapseTask?.cancel()
        attachmentTask?.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if inside {
                self.pendingCollapseOrigin = nil
                self.setExpanded(true)
            } else if !self.isPointerInRail, self.pendingCollapseOrigin == nil {
                self.scheduleCollapse()
            }
        }
    }

    private func scheduleCollapse() {
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, !self.isPointerInRail, !self.isPointerInAttachment else { return }
            guard !NSColorPanel.shared.isVisible else { return }
            // Hover exits can be spurious while the window is resizing under the pointer, so trust
            // the pointer's actual position over the last tracking event.
            if self.pointerIsOverVisibleContent {
                self.isPointerInRail = true
                self.scheduleCollapse()
                return
            }
            if self.store.displayMode == .hover {
                self.setExpanded(false)
            } else if !self.isAttachmentPinned {
                self.setAttachment(nil)
            }
        }
    }

    /// True when the pointer is over the rail or an open attachment, in screen coordinates.
    private var pointerIsOverVisibleContent: Bool {
        let location = NSEvent.mouseLocation
        return interactiveRects.contains { $0.insetBy(dx: -2, dy: 0).contains(location) }
    }

    private func providerHoverChanged(_ provider: ProviderID?) {
        attachmentTask?.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state.hoveredProvider = provider
            guard self.state.attachment != .settings else { return }

            if let provider {
                if self.isAttachmentPinned, case .detail = self.state.attachment { return }
                self.attachmentTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled, let self, self.state.hoveredProvider == provider else { return }
                    self.setAttachment(.detail(provider))
                }
            } else if !self.isAttachmentPinned {
                self.attachmentTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self, self.state.hoveredProvider == nil, !self.isPointerInAttachment else { return }
                    self.setAttachment(nil)
                }
            }
        }
    }

    private func providerSelected(_ provider: ProviderID) {
        attachmentTask?.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isAttachmentPinned, self.state.attachment == .detail(provider) {
                self.isAttachmentPinned = false
                self.setAttachment(nil)
            } else {
                self.isAttachmentPinned = true
                self.setAttachment(.detail(provider))
            }
        }
    }

    private func toggleSettings() {
        debugNote("toggle settings (was \(String(describing: state.attachment)))")
        attachmentTask?.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.state.attachment == .settings {
                self.isAttachmentPinned = false
                self.setAttachment(nil)
            } else {
                self.isAttachmentPinned = true
                self.setAttachment(.settings)
            }
        }
    }

    // MARK: - State transitions

    private func applyDisplayMode(animated: Bool) {
        switch store.displayMode {
        case .always:
            panel.orderFrontRegardless()
            setExpanded(true, animated: animated)
        case .hover:
            panel.orderFrontRegardless()
            isPointerInRail = panel.frame.contains(NSEvent.mouseLocation)
            if !isPointerInRail {
                isAttachmentPinned = false
                setAttachment(nil, animated: animated)
            }
            setExpanded(isPointerInRail, animated: animated)
        case .hidden:
            isAttachmentPinned = false
            setAttachment(nil, animated: false)
            panel.orderOut(nil)
        }
    }

    private func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard state.isExpanded != expanded || panel.frame.width == 0 else { return }
        if !expanded {
            isAttachmentPinned = false
            state.hoveredProvider = nil
            state.attachment = nil
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(animated && !reduceMotion ? .spring(duration: 0.2, bounce: 0.1) : .easeOut(duration: animated ? 0.1 : 0)) {
            state.isExpanded = expanded
        }
        positionPanel(animated: animated)
        routePointer()
    }

    private func setAttachment(_ attachment: EdgeAttachment?, animated: Bool = true) {
        guard state.attachment != attachment else { return }
        debugNote("attachment -> \(String(describing: attachment))")
        withAnimation(animated ? .easeOut(duration: 0.13) : nil) {
            state.attachment = attachment
        }
        positionPanel(animated: animated)
        routePointer()
    }

    // MARK: - Geometry

    private func scheduleDebugSnapshot() {
        guard let directory = Self.snapshotDirectory else { return }
        snapshotTask?.cancel()
        // GAUGEZ_DEBUG_BURST=1 also captures the in-between frames of each transition.
        let delays: [Int] = ProcessInfo.processInfo.environment["GAUGEZ_DEBUG_BURST"] != nil
            ? [16, 60, 120, 200, 450]
            : [450]
        snapshotTask = Task { [weak self] in
            var elapsed = 0
            self?.snapshotCounter += 1
            for delay in delays {
                try? await Task.sleep(for: .milliseconds(delay - elapsed))
                elapsed = delay
                guard !Task.isCancelled, let self else { return }
                self.writeDebugSnapshot(to: directory, suffix: delays.count > 1 ? "-\(delay)ms" : "")
            }
        }
    }

    private func writeDebugSnapshot(to directory: String, suffix: String) {
        guard let view = panel.contentView else { return }
        debugNote("snapshot\(suffix): window \(Int(panel.frame.width))x\(Int(panel.frame.height)) hosting \(Int(view.bounds.width))x\(Int(view.bounds.height)) expanded=\(state.isExpanded)")
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let label: String
        switch state.attachment {
        case .detail(let provider): label = "card-\(provider.rawValue)"
        case .settings: label = "settings"
        case nil: label = state.isExpanded ? "expanded" : "collapsed"
        }
        let name = String(format: "%02d-%@%@.png", snapshotCounter, label, suffix)
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// The window is always its maximum size and never resizes; transparent areas pass pointer
    /// events through to whatever is behind, so only the drawn rail and cards are interactive.
    private func positionPanel(animated: Bool) {
        defer { scheduleDebugSnapshot() }
        guard let screen = preferredScreen else { return }
        let visibleFrame = screen.visibleFrame
        let width = RailMetrics.maximumPanelWidth
        let height = RailMetrics.panelHeight(providerCount: store.visibleProviders.count)
        let x = store.edgeSide == .right ? visibleFrame.maxX - width : visibleFrame.minX
        let y = visibleFrame.midY - height / 2
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    private var preferredScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
    }
}

private final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
