import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Owns the borderless edge panel and the hover state machine:
/// collapsed tab -> expanded rail -> anchored detail card / attached settings.
@MainActor
final class EdgePanelController {
    private let displayID: String?
    private let expansionID = UUID()
    private var peekTask: Task<Void, Never>?
    private var peekEvent: SessionCompletionWatcher.Event?
    private let store: UsageStore
    private let updates: UpdateManager
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
    private var isDragging = false
    /// The resize grip's last reported frame, in panel coordinates with a top-left origin.
    private var resizeGripFrame: CGRect = .null
    /// A resize drag is in flight, so the cursor stays the resize arrows wherever the pointer is.
    private var isResizingRail = false
    /// Whether the resize cursor is what this controller last set.
    private var showsResizeCursor = false
    /// The app that was active before GaugeZ took activation for the resize cursor, to be
    /// given it back the moment the pointer leaves the grip.
    private var appBeforeResizeCursor: NSRunningApplication?
    /// The usable area the rail was last placed against; see `followUsableAreaIfItMoved`.
    private var lastUsableArea: NSRect = .zero
    private var usableAreaTimer: Timer?
    /// The rail in the hand; see `Carry`.
    private var carry: Carry?
    private lazy var passage = RailPassageOverlay(store: store)
    private var ticker: DisplayTicker?
    /// Where the carried rail sits on the edge it started from, in place of the saved position
    /// until it is let go — the saved one is written once, on landing.
    private var livePosition: Double?
    private var dragMonitor: Any?
    /// The rail is ordered out because a full-screen app owns this display.
    private var isFoldedForFullScreen = false
    private var fullScreenTick = 0

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

    init(store: UsageStore, updates: UpdateManager, displayID: String? = nil) {
        self.displayID = displayID
        self.store = store
        self.updates = updates
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
        installUsableAreaWatch()
        applyDisplayMode(animated: false)
        runDemoIfRequested()
    }

    deinit {
        for monitor in pointerMonitors {
            NSEvent.removeMonitor(monitor)
        }
        usableAreaTimer?.invalidate()
    }

    /// An auto-hiding Dock revealing or concealing itself, or moving to another edge, changes the
    /// usable screen area without posting `didChangeScreenParametersNotification`. Nothing tells the
    /// rail, so it asks: the visible frame is compared on a timer and on pointer movement.
    private func installUsableAreaWatch() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.followUsableAreaIfItMoved()
                // The window list is the costly half of this check, so it runs every fourth
                // tick; app and Space changes re-run it at once (see `observeSettings`).
                if let self, self.fullScreenTick % 4 == 0 { self.updateFullScreenFold() }
                self?.fullScreenTick += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        usableAreaTimer = timer
    }

    private func followUsableAreaIfItMoved() {
        guard !isDragging, let frame = preferredScreen?.visibleFrame, frame != lastUsableArea else { return }
        debugNote("usable area moved to \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        positionPanel(animated: false)
    }

    /// Steps out of the way of a full-screen app on this display, and comes back with the Space.
    private func updateFullScreenFold() {
        let fold = store.hideOverFullScreen && store.displayMode != .hidden && !isDragging
            && preferredScreen.map(FullScreenDetector.isFullScreenAppFrontmost(on:)) == true
        guard fold != isFoldedForFullScreen else { return }
        isFoldedForFullScreen = fold
        debugNote("full-screen fold \(fold)")
        if fold {
            panel.orderOut(nil)
        } else if store.displayMode != .hidden {
            panel.orderFrontRegardless()
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
        followUsableAreaIfItMoved()
        if isDragging {
            if panel.ignoresMouseEvents {
                panel.ignoresMouseEvents = false
            }
            return
        }
        let location = NSEvent.mouseLocation
        let over = interactiveRects.contains { $0.contains(location) }
        if panel.ignoresMouseEvents == over {
            panel.ignoresMouseEvents = !over
            debugNote("pointer \(over ? "over" : "off") content at \(Int(location.x)),\(Int(location.y)) rects \(interactiveRects.map { "\(Int($0.minX))-\(Int($0.maxX))" })")
        }
        updateResizeCursor()
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

    /// The resize grip on screen, from the frame the handle last reported.
    private var resizeGripScreenRect: NSRect {
        guard !resizeGripFrame.isNull else { return .null }
        let frame = panel.frame
        return NSRect(x: frame.minX + resizeGripFrame.minX,
                      y: frame.maxY - resizeGripFrame.maxY,
                      width: resizeGripFrame.width, height: resizeGripFrame.height)
    }

    /// The resize cursor over the grip, and only there.
    ///
    /// macOS honours a cursor only from the active app; from any other it is refused outright,
    /// however it is set — `NSCursor.current` changes and the pointer on screen does not.
    /// This panel is non-activating by design, so GaugeZ is almost never the active app while
    /// the pointer is on it (Codenotch's pointing hand is refused the same way). So for the
    /// resize cursor, and only for it, GaugeZ takes activation while the pointer is on the
    /// grip — a 48pt-by-8pt mark you reach on purpose — and hands it straight back to the app
    /// that had it the moment the pointer leaves or the drag ends. That app loses key focus
    /// for that moment, which is the price of a real cursor here.
    private func updateResizeCursor() {
        let location = NSEvent.mouseLocation
        let onGrip = state.isExpanded && resizeGripScreenRect.insetBy(dx: -2, dy: -2).contains(location)
        if state.resizeGripHovered != onGrip { state.resizeGripHovered = onGrip }
        if onGrip || isResizingRail {
            if !showsResizeCursor {
                showsResizeCursor = true
                if !NSApp.isActive {
                    appBeforeResizeCursor = NSWorkspace.shared.frontmostApplication
                    NSApp.activate(ignoringOtherApps: true)
                }
                store.edgeSide.resizeCursor.push()
            } else {
                // Activation lands a beat after it is asked for; the cursor set alongside it
                // was refused, so it is set again on every move until it shows.
                store.edgeSide.resizeCursor.set()
            }
        } else if showsResizeCursor {
            showsResizeCursor = false
            NSCursor.pop()
            if let app = appBeforeResizeCursor, app != .current {
                app.activate()
            }
            appBeforeResizeCursor = nil
        }
    }

    /// Screen rects of the drawn, interactive parts: the rail column and, when open, the card column.
    private var interactiveRects: [NSRect] {
        let frame = panel.frame
        let scale = CGFloat(store.railScale)
        if store.edgeSide.isHorizontal {
            let top = store.edgeSide == .top
            let inset = top ? state.topInset : 0
            let contentTop = frame.maxY - inset
            let depth = HorizontalRailMetrics.depth(scale: scale)
            let railHeight = state.isExpanded ? depth : RailMetrics.collapsedWidth
            let railWidth = RailMetrics.shapeHeight(providerCount: store.railProviders.count, scale: scale)
            let rail = NSRect(x: frame.midX - railWidth / 2,
                              y: top ? contentTop - railHeight : frame.minY,
                              width: railWidth, height: railHeight)
            var rects = [rail]
            if top, let notch = state.joinedNotch {
                // The hardware notch is the tab while the rail rests; hovering it opens the rail.
                // With rings beside it, the band they sit in is part of the tab.
                let perSide = store.notchRingsEnabled && !state.isExpanded
                    ? NotchEarsMetrics.perSide(count: store.railProviders.count, notch: notch, available: frame.width)
                    : 0
                let width = NotchEarsMetrics.width(perSide: perSide, notch: notch)
                rects.append(NSRect(x: frame.midX - width / 2, y: frame.maxY - notch.height,
                                    width: width, height: notch.height))
            }
            if state.isExpanded, state.attachment != nil {
                let width = RailMetrics.attachmentWidth - RailMetrics.pointerDepth
                let height = min(state.attachmentHeight + HorizontalRailMetrics.cardGap, max(0, frame.height - inset - depth))
                rects.append(NSRect(x: frame.midX - width / 2,
                                    y: top ? contentTop - depth - height : frame.minY + depth,
                                    width: width, height: height))
            }
            return rects
        }
        let railWidth = state.isExpanded ? RailMetrics.expandedWidth(scale: scale) : RailMetrics.collapsedWidth
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
            for page in 0..<self.store.railPageCount {
                self.store.railPage = page
                try? await Task.sleep(for: step)
                for provider in self.store.railProviders {
                    self.providerHoverChanged(provider)
                    try? await Task.sleep(for: step)
                }
            }
            self.providerHoverChanged(nil)
            self.toggleSettings()
            try? await Task.sleep(for: step)
            self.toggleSettings()
            self.railHoverChanged(false)
            try? await Task.sleep(for: step)
            // The limit-event cards, from a folded rail as in real life: reached, then
            // reset, then folded away by dismissal.
            self.setExpanded(false)
            try? await Task.sleep(for: step)
            self.store.previewUsageEvent(.limitReached)
            try? await Task.sleep(for: step)
            self.store.previewUsageEvent(.limitReset)
            try? await Task.sleep(for: step)
            self.store.dismissUsageEvent()
            try? await Task.sleep(for: step)
            NotificationCenter.default.post(name: .gaugezOpenSettings, object: nil)
        }
    }

    var isExpanded: Bool {
        state.isExpanded
    }

    func show() {
        guard store.displayMode != .hidden, !isFoldedForFullScreen else { return }
        positionPanel(animated: false)
        panel.orderFrontRegardless()
    }

    func close() {
        peekTask?.cancel()
        collapseTask?.cancel()
        attachmentTask?.cancel()
        cancellables.removeAll()
        store.expandedPanels.remove(expansionID)
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors.removeAll()
        usableAreaTimer?.invalidate()
        endCarry()
        passage.hide()
        panel.close()
    }

    /// A limit event is announcing itself: the rail holds open until the store clears it,
    /// the way a session completion holds until its peek timer ends.
    private var usageEventHoldOpen = false

    private func usageEventPeekChanged(_ event: UsageEvent?) {
        debugNote("usage event -> \(event.map { "\($0.kind) \($0.provider.rawValue)" } ?? "nil") dragging=\(isDragging) mode=\(store.displayMode) attachment=\(String(describing: state.attachment)) pinned=\(isAttachmentPinned)")
        guard let event else {
            // The store dismissed it (its timer or the banner's button). The hold is released
            // even mid-drag — a release that landed while dragging must not outlive the drag —
            // and the rail folds when the pointer is nowhere near it, otherwise control goes
            // back to the hover machine.
            usageEventHoldOpen = false
            guard !isDragging else { return }
            if peekEvent == nil, !isAttachmentPinned, !pointerIsOverVisibleContent {
                setAttachment(nil)
                if store.displayMode == .hover { setExpanded(false) }
            }
            return
        }
        // Only a card that actually opens holds the rail: a peek refused for a pinned card,
        // open settings, or a hidden rail must not block the next collapse.
        guard !isDragging, store.displayMode != .hidden, !isFoldedForFullScreen, state.attachment != .settings, !isAttachmentPinned else { return }
        usageEventHoldOpen = true
        // A session peek in progress hands over: its timer was the only thing clearing
        // `peekEvent`, so the event goes with it or the rail never folds again.
        peekTask?.cancel()
        peekEvent = nil
        collapseTask?.cancel()
        attachmentTask?.cancel()
        if let index = store.visibleProviders.firstIndex(of: event.provider) {
            store.railPage = index / store.railPageCapacity
        }
        setExpanded(true)
        setAttachment(.detail(event.provider))
    }

    /// A new version found in the background is offered on the rail once, open until it is
    /// answered. Settings the user opened are not pushed aside for it; it waits for the next
    /// time the rail is free.
    private func offerUpdateIfDue() {
        guard updates.updateToOffer != nil else {
            if state.attachment == .update { setAttachment(nil) }
            return
        }
        guard !isDragging, store.displayMode != .hidden, !isFoldedForFullScreen,
              state.attachment != .settings, !usageEventHoldOpen, peekEvent == nil else { return }
        // On every display at once would be one question asked several times.
        if displayID != nil, displayID != NSScreen.main.map(DisplayChoice.identifier(for:)) { return }
        collapseTask?.cancel()
        attachmentTask?.cancel()
        setExpanded(true)
        isAttachmentPinned = true
        setAttachment(.update)
    }

    private func updateChosen(_ install: Bool) {
        if install {
            updates.checkForUpdates()
        } else {
            updates.deferPendingUpdate()
        }
        isAttachmentPinned = false
        setAttachment(nil)
        if store.displayMode == .hover, !pointerIsOverVisibleContent { setExpanded(false) }
    }

    private func peek(_ event: SessionCompletionWatcher.Event) {
        guard store.displayMode != .hidden, !isFoldedForFullScreen, state.attachment != .settings, !isAttachmentPinned, !isDragging else { return }
        usageEventHoldOpen = false
        peekTask?.cancel()
        collapseTask?.cancel()
        attachmentTask?.cancel()
        peekEvent = event
        if let index = store.visibleProviders.firstIndex(of: event.session.provider) {
            store.railPage = index / store.railPageCapacity
        }
        setExpanded(true)
        setAttachment(.detail(event.session.provider))
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.store.sessionPeekSeconds ?? 5))
            guard !Task.isCancelled, let self else { return }
            self.peekEvent = nil
            if !self.pointerIsOverVisibleContent, !self.isAttachmentPinned {
                self.setAttachment(nil)
                if self.store.displayMode == .hover { self.setExpanded(false) }
            }
        }
    }

    func setVisibility(_ expanded: Bool) {
        if !expanded {
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
        // Pinned dark on the window, not just in SwiftUI's environment: the Liquid Glass
        // backdrop resolves its material against the window's appearance, and the rail's ink
        // is white throughout. Left to follow the Mac, light mode would draw light glass under
        // white text.
        panel.appearance = NSAppearance(named: .darkAqua)
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
            gearZoneHover: { [weak self] _ in self?.scheduleDebugSnapshot() },
            dragStarted: { [weak self] in self?.dragStarted() },
            dragMoved: { [weak self] screenY in self?.dragMoved(screenY: screenY) },
            dragEnded: { [weak self] in self?.dragEnded() },
            resizeGripFrameChanged: { [weak self] frame in self?.resizeGripFrame = frame },
            railResizeChanged: { [weak self] resizing in
                self?.isResizingRail = resizing
                if !resizing { self?.routePointer() }
            },
            updateChosen: { [weak self] install in self?.updateChosen(install) }
        )
        let root = EdgePanelContentView(state: state, actions: actions)
            .environmentObject(store)
            .environmentObject(updates)
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
        store.sessionCompletions.sink { [weak self] event in self?.peek(event) }.store(in: &cancellables)
        updates.$pendingUpdateVersion
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.offerUpdateIfDue() }
            .store(in: &cancellables)
        store.$usageEventPeek
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.usageEventPeekChanged(event) }
            .store(in: &cancellables)
        store.$railPage.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // A peek — session or limit event — opens by paging to its provider, and
                // that page change must not close the card it just opened.
                guard self.peekEvent == nil, !self.usageEventHoldOpen else { self.positionPanel(animated: false); return }
                self.attachmentTask?.cancel()
                self.state.hoveredProvider = nil
                self.isAttachmentPinned = false
                self.setAttachment(nil)
                self.positionPanel(animated: false)
            }.store(in: &cancellables)
        store.$selectedDisplayID.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.edgeSideChanged() }.store(in: &cancellables)
        store.$providerOrder.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.positionPanel(animated: false) }.store(in: &cancellables)
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

        store.$verticalPosition
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, !self.isDragging else { return }
                    self.positionPanel(animated: true)
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

        store.$railScale
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.positionPanel(animated: false)
                    self?.routePointer()
                }
            }
            .store(in: &cancellables)

        store.$notchRingsEnabled.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.routePointer() }.store(in: &cancellables)
        store.$hideOverFullScreen.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFullScreenFold() }.store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            // A full-screen transition animates; the window list settles a moment after the notice.
            workspace.publisher(for: name).delay(for: .milliseconds(700), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateFullScreenFold() }.store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.store.updateSystemSettings()
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
        positionPanel(animated: false)
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
        guard !isDragging else { return }
        isPointerInRail = inside
        collapseTask?.cancel()
        guard store.displayMode == .hover else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDragging else { return }
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
        guard !isDragging else { return }
        isPointerInAttachment = inside
        collapseTask?.cancel()
        attachmentTask?.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDragging else { return }
            if inside {
                self.pendingCollapseOrigin = nil
                self.setExpanded(true)
            } else if !self.isPointerInRail, self.pendingCollapseOrigin == nil {
                self.scheduleCollapse()
            }
        }
    }

    private func scheduleCollapse() {
        guard !isDragging, peekEvent == nil, !usageEventHoldOpen, state.attachment != .update else { return }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, !self.isPointerInRail, !self.isPointerInAttachment, !self.isDragging else { return }
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
        guard !isDragging else { return }
        attachmentTask?.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDragging else { return }
            self.state.hoveredProvider = provider
            guard self.state.attachment != .settings, self.state.attachment != .update else { return }

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
        usageEventHoldOpen = false
        if let event = peekEvent, event.session.provider == provider {
            SessionFocus.activate(event.session)
            peekEvent = nil
            peekTask?.cancel()
            if store.displayMode == .hover { setExpanded(false) }
            return
        }
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
            if !isFoldedForFullScreen { panel.orderFrontRegardless() }
            setExpanded(true, animated: animated)
        case .hover:
            if !isFoldedForFullScreen { panel.orderFrontRegardless() }
            isPointerInRail = panel.frame.contains(NSEvent.mouseLocation)
            if !isPointerInRail {
                isAttachmentPinned = false
                setAttachment(nil, animated: animated)
            }
            setExpanded(isPointerInRail, animated: animated)
        case .hidden:
            store.expandedPanels.remove(expansionID)
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
        if expanded { store.expandedPanels.insert(expansionID) } else { store.expandedPanels.remove(expansionID) }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Joined to the Mac's notch the rail pours out from under it, on the notch's own spring.
        let spring: Animation = state.joinedNotch != nil ? NotchMotion.drip(opening: expanded) : .spring(duration: 0.2, bounce: 0.1)
        withAnimation(animated && !reduceMotion ? spring : .easeOut(duration: animated ? 0.1 : 0)) {
            state.isExpanded = expanded
        }
        positionPanel(animated: animated)
        routePointer()
    }

    private func setAttachment(_ attachment: EdgeAttachment?, animated: Bool = true) {
        guard state.attachment != attachment else { return }
        debugNote("attachment -> \(String(describing: attachment))")
        withAnimation(animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.13) : nil) {
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
        case .update: label = "update"
        case nil: label = state.isExpanded ? "expanded" : "collapsed"
        }
        let name = String(format: "%02d-%@%@.png", snapshotCounter, label, suffix)
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    // MARK: - Vertical bounds & Dragging

    private func verticalBounds(screen: NSScreen, height: CGFloat) -> (minY: CGFloat, maxY: CGFloat, range: CGFloat) {
        let visibleFrame = screen.visibleFrame
        let verticalMargin: CGFloat = 12
        let minY = visibleFrame.minY + verticalMargin
        let maxY = max(minY, visibleFrame.maxY - height - verticalMargin)
        return (minY, maxY, maxY - minY)
    }

    // MARK: - Carrying the rail round the border

    /// **The rail in the hand.** Its place is a position on the usable area's border — see
    /// `BorderTrack` — following the pointer's place on it at the distance it was picked up
    /// at, on a spring. Fully on the edge it started from it is the rail itself, sliding;
    /// reaching round a corner, or on any other edge, it is drawn on the passage surface
    /// instead, and the rail's own window waits out of sight until it is let go.
    private struct Carry {
        let track: BorderTrack
        let landing: RailLanding
        let startEdge: EdgeSide
        /// The outline drawn in the passage: the notch, without its settings button.
        let bodyLength: CGFloat
        let depth: CGFloat
        let scale: CGFloat
        /// Where the notch body's middle is along the border from the rail's middle: the
        /// settings button hangs off one end, so the body sits towards the other.
        let bodyOffset: CGFloat
        /// What the rail carries — each ring and the settings button — as distances along
        /// the border from its middle, in the order the rail lays them out where it started.
        let contents: [(provider: ProviderID?, offset: CGFloat)]
        var grip: CGFloat
        var reading: BorderTrack.Reading
        var pointerEdge: EdgeSide
        var target: CGFloat
        var shown: CGFloat
        var velocity: CGFloat = 0
        var snapped: Bool
        /// Set when it is let go: where it settles.
        var land: (edge: EdgeSide, saved: Double)?
        var inPassage = false
        /// Where the passage was last drawn, so a rail held still is not redrawn every frame.
        var drawnAt: CGFloat?
    }

    private func railLanding(on screen: NSScreen) -> RailLanding {
        let scale = CGFloat(store.railScale)
        let count = store.railProviders.count
        return RailLanding(track: BorderTrack(frame: screen.visibleFrame),
                           railLength: RailMetrics.shapeHeight(providerCount: count, scale: scale),
                           horizontalPanelWidth: HorizontalRailMetrics.width(providerCount: count, scale: scale))
    }

    private func dragStarted() {
        debugNote("drag started")
        // Picked up again while still settling from the last drop: that drop lands at once.
        if var landing = carry, landing.land != nil {
            landing.target = landing.shown
            carry = landing
            finishLanding()
        }
        guard carry == nil, let screen = preferredScreen else { return }
        isDragging = true
        collapseTask?.cancel()
        attachmentTask?.cancel()
        setAttachment(nil, animated: false)
        panel.ignoresMouseEvents = false

        let landing = railLanding(on: screen)
        let track = landing.track
        let scale = CGFloat(store.railScale)
        let middle = landing.position(saved: store.verticalPosition, on: store.edgeSide)
        let pointer = NSEvent.mouseLocation
        let edge = track.nearestEdge(to: pointer, current: store.edgeSide)
        let reading = track.reading(of: pointer, nearest: edge)
        // Measured from the rail's head (the drag handle) along it, as the side rail lays
        // itself out; the head points anticlockwise on the right and top edges and clockwise
        // on the left and bottom, which is how the horizontal rails are turned.
        let providers = store.railProviders
        let shapeHeight = RailMetrics.shapeHeight(providerCount: providers.count, scale: scale)
        let notchHeight = RailMetrics.notchHeight(providerCount: providers.count, scale: scale)
        let footward: CGFloat = store.edgeSide == .right || store.edgeSide == .top ? 1 : -1
        let fromHead = { (distance: CGFloat) in footward * (distance - shapeHeight / 2) }
        let rowHeight = RailMetrics.rowHeight(scale: scale)
        let ringSize = RailMetrics.ringSize(scale: scale)
        var contents: [(provider: ProviderID?, offset: CGFloat)] = providers.enumerated().map { index, provider in
            (provider, fromHead(RailMetrics.rowCenterY(index: index, scale: scale) - ringSize / 2 + rowHeight / 2))
        }
        contents.append((nil, fromHead(notchHeight - (11 * scale).rounded())))
        carry = Carry(track: track, landing: landing, startEdge: store.edgeSide,
                      bodyLength: notchHeight,
                      depth: RailMetrics.expandedWidth(scale: scale), scale: scale,
                      bodyOffset: fromHead(notchHeight / 2), contents: contents,
                      grip: track.delta(from: track.place(of: pointer, by: reading), to: middle),
                      reading: reading, pointerEdge: edge, target: middle, shown: middle,
                      snapped: abs(store.verticalPosition - 0.5) < 0.001)
        // Picked up out of a landing that had not handed back yet, the rail is still hidden.
        carry?.inPassage = panel.alphaValue < 0.5
        passage.place(over: track.frame)
        // The grip reports the drag, but it lives in the rail's window, which is out of sight
        // while the rail is in the passage. The app's own event stream is watched as well, so
        // letting go always lands it.
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if event.type == .leftMouseUp { self?.dragEnded() } else { self?.dragMoved(screenY: 0) }
            return event
        }
        if let host = panel.contentView {
            ticker = DisplayTicker(view: host) { [weak self] dt in self?.follow(dt: dt) }
        }
    }

    private func dragMoved(screenY: CGFloat) {
        guard var carry, carry.land == nil else { return }
        let track = carry.track
        let pointer = NSEvent.mouseLocation
        let edge = track.nearestEdge(to: pointer, current: carry.pointerEdge)
        let reading = track.reading(of: pointer, nearest: edge)
        if reading != carry.reading {
            // Read another way, the pointer is somewhere slightly different on the border;
            // the grip takes up the difference so the rail does not jump.
            carry.grip += track.delta(from: track.place(of: pointer, by: reading),
                                      to: track.place(of: pointer, by: carry.reading))
            carry.reading = reading
        }
        carry.pointerEdge = edge
        var target = track.wrapped(track.place(of: pointer, by: reading) + carry.grip)
        // The middle of an edge holds the rail a moment, with a tap. On top of a MacBook that
        // is where it joins the notch.
        let (onEdge, along) = track.place(at: target)
        let range = carry.landing.range(on: onEdge)
        let centre = track.length(of: onEdge) / 2
        let inSnap = range.contains(along)
            && abs(along - centre) < max(6, (range.upperBound - range.lowerBound) * 0.025)
        if inSnap {
            target = track.start(of: onEdge) + centre
            if !carry.snapped { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default) }
        }
        carry.snapped = inSnap
        carry.target = target
        self.carry = carry
    }

    private func dragEnded() {
        guard var carry, carry.land == nil else { return }
        let landing = carry.landing.landing(for: carry.target)
        debugNote("drag let go: lands on \(landing.edge) at \(landing.saved)")
        carry.land = (landing.edge, landing.saved)
        carry.target = landing.position
        self.carry = carry
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
    }

    /// **The rail follows the hand on a spring**: it carries its speed, catches up, and comes
    /// to rest with the smallest give, instead of being pushed point for point. Let go, it
    /// settles on a softer one.
    private func follow(dt: CFTimeInterval) {
        guard var carry else { stopTicker(); return }
        let track = carry.track
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            carry.shown = carry.target
            carry.velocity = 0
        } else {
            let offset = track.delta(from: carry.target, to: carry.shown)
            let omega: CGFloat = carry.land == nil ? 42 : 26
            let damping: CGFloat = 0.86
            let step = CGFloat(dt)
            carry.velocity += (-omega * omega * offset - 2 * damping * omega * carry.velocity) * step
            carry.shown = track.wrapped(carry.shown + carry.velocity * step)
        }
        let settled = abs(track.delta(from: carry.target, to: carry.shown)) < 0.4 && abs(carry.velocity) < 8
        if settled {
            carry.shown = carry.target
            carry.velocity = 0
        }
        show(&carry)
        self.carry = carry
        if settled, carry.land != nil { finishLanding() }
    }

    /// Puts the carried rail where the spring has it: the rail itself on its own edge, the
    /// passage anywhere else.
    private func show(_ carry: inout Carry) {
        let track = carry.track
        let (edge, along) = track.place(at: carry.shown)
        let range = carry.landing.range(on: edge)
        // Out to the passage as soon as it leaves the range it can rest in; back to the rail
        // only once clearly inside it again. Handed across at one exact point, the smallest
        // movement there swapped the two back and forth, and each swap cut the last one short.
        let margin: CGFloat = carry.inPassage ? 24 : 0
        let onOwnEdge = edge == carry.startEdge
            && along >= range.lowerBound + margin && along <= range.upperBound - margin
        if onOwnEdge {
            livePosition = carry.landing.savedPosition(along: along, on: edge)
            positionPanel(animated: false)
        } else if !carry.inPassage || carry.drawnAt.map({ abs($0 - carry.shown) >= 0.25 }) ?? true {
            carry.drawnAt = carry.shown
            let items = carry.contents.flatMap { item in
                placements(track, of: item.provider, at: carry.shown + item.offset, depth: carry.depth)
            }
            passage.draw(RailPassageShape.path(track: track, middle: carry.shown + carry.bodyOffset,
                                               length: carry.bodyLength, depth: carry.depth, scale: carry.scale),
                         items: items, scale: carry.scale)
        }
        if onOwnEdge == carry.inPassage {
            carry.inPassage = !onOwnEdge
            // A straight swap: the outline is drawn exactly where the rail is, so there is
            // nothing to fade between, and a fade left both half there — the rail's rings
            // blurred through the glass.
            crossFade(toPassage: carry.inPassage, duration: 0)
        }
    }

    /// **Where something the rail carries is drawn**, at a border position: in the middle of
    /// the band, on its own edge's line, turning onto the next edge's line where the two
    /// bands' middles meet. Whole, as Codenotch draws them: round the bend they bunch up and
    /// briefly overlap, which reads as the rail being bent; cut at the corner's diagonal they
    /// read as being sliced.
    private func placements(_ track: BorderTrack, of provider: ProviderID?, at position: CGFloat, depth: CGFloat) -> [PassageItem] {
        let half = depth / 2
        let (edge, along) = track.place(at: position)
        let a = min(max(along, half), max(half, track.length(of: edge) - half))
        let centre: CGPoint
        switch edge {
        case .top: centre = CGPoint(x: a, y: half)
        case .right: centre = CGPoint(x: track.width - half, y: a)
        case .bottom: centre = CGPoint(x: track.width - a, y: track.height - half)
        case .left: centre = CGPoint(x: half, y: track.height - a)
        }
        return [PassageItem(provider: provider, centre: centre, cut: nil)]
    }

    private func crossFade(toPassage: Bool, duration: TimeInterval? = nil) {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (duration ?? 0.12)
        passage.fade(in: toPassage, duration: duration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = toPassage ? 0 : 1
        }
    }

    private func finishLanding() {
        guard let carry, let land = carry.land else { return }
        endCarry()
        store.verticalPosition = land.saved
        if store.edgeSide != land.edge { store.edgeSide = land.edge }
        positionPanel(animated: false)
        if carry.inPassage {
            // The rail's window lays itself out for the new edge on the next pass; the passage
            // holds the shape until then.
            panel.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                // Unless it has been picked up again meanwhile.
                guard let self, self.carry == nil else { return }
                self.crossFade(toPassage: false)
            }
        }
        routePointer()
    }

    /// Drops whatever is in the hand, without landing it.
    private func endCarry() {
        ticker?.stop()
        ticker = nil
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
        carry = nil
        livePosition = nil
        isDragging = false
        panel.alphaValue = 1
    }

    private func stopTicker() {
        ticker?.stop()
        ticker = nil
    }

    /// The window is always its maximum size and never resizes; transparent areas pass pointer
    /// events through to whatever is behind, so only the drawn rail and cards are interactive.
    private func positionPanel(animated: Bool) {
        defer { scheduleDebugSnapshot() }
        guard let screen = preferredScreen else { return }
        let visibleFrame = screen.visibleFrame
        lastUsableArea = visibleFrame
        let position = livePosition ?? store.verticalPosition
        let frame: NSRect
        let scale = CGFloat(store.railScale)
        if store.edgeSide.isHorizontal {
            // On a MacBook's top edge the rail joins the display's own notch: the panel runs up
            // to the screen's real top so the notch is inside it (as the hover target), the
            // content is inset below the menu bar band, and the rail is centered under the
            // notch rather than at the user's chosen position.
            // Only in the middle: carried along the top edge the rail slides freely under the
            // menu bar, and snaps into the notch as it passes the centre.
            let notch = store.edgeSide == .top && abs(position - 0.5) < 0.001 ? screen.hardwareNotch : nil
            let inset: CGFloat = notch.map { max($0.height, screen.frame.maxY - visibleFrame.maxY) } ?? 0
            let width = min(HorizontalRailMetrics.width(providerCount: store.railProviders.count, scale: scale), visibleFrame.width)
            let height = min(620, visibleFrame.height) + inset
            let x = notch != nil
                ? (screen.frame.midX - width / 2).rounded()
                : visibleFrame.minX + max(0, visibleFrame.width - width) * CGFloat(position)
            let top = notch != nil ? screen.frame.maxY : visibleFrame.maxY
            let y = store.edgeSide == .top ? top - height : visibleFrame.minY
            frame = NSRect(x: x, y: y, width: width, height: height)
            if state.topInset != inset { state.topInset = inset }
            if state.joinedNotch != notch { state.joinedNotch = notch }
        } else {
            if state.topInset != 0 { state.topInset = 0 }
            if state.joinedNotch != nil { state.joinedNotch = nil }
            let width = RailMetrics.maximumPanelWidth(scale: scale)
            let height = RailMetrics.panelHeight(providerCount: store.railProviders.count, scale: scale)
            let x = store.edgeSide == .right ? visibleFrame.maxX - width : visibleFrame.minX
            let bounds = verticalBounds(screen: screen, height: height)
            let y = bounds.minY + bounds.range * CGFloat(position)
            frame = NSRect(x: x, y: y, width: width, height: height)
        }
        if panel.frame != frame {
            if animated && !isDragging && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
    }

    private var preferredScreen: NSScreen? {
        NSScreen.screens.first(where: { DisplayChoice.identifier(for: $0) == (displayID ?? store.selectedDisplayID) })
            ?? NSScreen.screens.first
    }
}

private final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
