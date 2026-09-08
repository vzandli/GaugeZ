import AppKit
import SwiftUI

/// What changed in this version, shown once on the first launch after an update.
struct WhatsNewView: View {
    let note: ReleaseNote
    let onContinue: () -> Void

    /// Fixed, with the list scrolling inside: a window sized to its content jumps between
    /// releases of different lengths.
    static let width: CGFloat = 440
    static let height: CGFloat = 480

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .padding(.bottom, 6)
                HStack(spacing: 6) {
                    Text("What's new in")
                    GaugeZWordmark(size: 19)
                }
                .font(.system(size: 19, weight: .semibold))
                Text("Version \(note.version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(note.headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(note.changes.enumerated()), id: \.offset) { _, change in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(Color(red: 0.19, green: 0.82, blue: 0.35))
                                .frame(width: 6, height: 6)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.title)
                                    .font(.callout.weight(.medium))
                                if !change.detail.isEmpty {
                                    Text(change.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            HStack {
                Spacer(minLength: 0)
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: Self.width, height: Self.height)
        .background(Color(red: 0.048, green: 0.055, blue: 0.071))
        .preferredColorScheme(.dark)
    }
}

/// Puts up the What's New window once per version. Its own window rather than a sheet: on most
/// launches no other window is open for a sheet to attach to.
@MainActor
final class WhatsNewWindowController {
    static let lastSeenKey = "lastSeenVersion"

    var onDismiss: (() -> Void)?

    private var window: NSWindow?
    private let version: String
    private let defaults: UserDefaults

    init(version: String, defaults: UserDefaults = .standard) {
        self.version = version
        self.defaults = defaults
    }

    var lastSeenVersion: String? { defaults.string(forKey: Self.lastSeenKey) }

    /// Records the running version as seen without showing anything: a fresh install has
    /// nothing to be "new" relative to, and gets the introduction instead.
    func markSeen() {
        defaults.set(version, forKey: Self.lastSeenKey)
    }

    /// Returns whether a window was shown, so the caller can sequence what follows.
    @discardableResult
    func showIfNeeded() -> Bool {
        guard let note = ReleaseNotes.unseen(in: version, lastSeen: lastSeenVersion) else {
            // A version with nothing written for it is still recorded, or it would surface
            // later, long after it was current, the first time a note happened to exist.
            markSeen()
            return false
        }
        show(note)
        return true
    }

    private func show(_ note: ReleaseNote) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WhatsNewView.width, height: WhatsNewView.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "What's New in GaugeZ"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.048, green: 0.055, blue: 0.071, alpha: 1)
        window.contentView = NSHostingView(rootView: WhatsNewView(note: note) { [weak self] in self?.dismiss() })
        window.center()
        window.isReleasedWhenClosed = false
        // Closing by the red button counts as read, the same as Continue.
        window.delegate = closeWatcher
        self.window = window
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Idempotent: closing by the red button arrives through `windowWillClose`, and this closes
    /// the window, so the guard and dropping the delegate first keep it from recursing.
    func dismiss() {
        guard let window else { return }
        self.window = nil
        // Recorded on dismiss, not on show: a crash in between must not swallow the one launch
        // this was going to appear on.
        markSeen()
        window.delegate = nil
        window.close()
        onDismiss?()
    }

    private lazy var closeWatcher = WhatsNewCloseWatcher { [weak self] in self?.dismiss() }
}

private final class WhatsNewCloseWatcher: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}
