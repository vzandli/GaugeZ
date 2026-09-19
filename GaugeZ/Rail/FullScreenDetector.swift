// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import AppKit
import CoreGraphics

/// Whether the frontmost app fills a display. Only window owners, layers and bounds are read,
/// which need no Screen Recording permission.
enum FullScreenDetector {
    typealias Window = (pid: pid_t, layer: Int, bounds: CGRect)

    /// Pure: does a layer-0 window of `frontmostPID` span `screenBounds` (CoreGraphics coordinates)?
    static func isFullScreen(screenBounds: CGRect, frontmostPID: pid_t, windows: [Window], safeAreaTopInset: CGFloat = 0) -> Bool {
        for window in windows where window.pid == frontmostPID && window.layer == 0 {
            let b = window.bounds
            guard abs(b.minX - screenBounds.minX) <= 4, abs(b.width - screenBounds.width) <= 4 else { continue }
            // A video, a game, or a full-screen Space on a display without a camera housing.
            if abs(b.minY - screenBounds.minY) <= 4, abs(b.height - screenBounds.height) <= 4 { return true }
            // On a notched MacBook a full-screen window starts below the housing and reaches the bottom.
            let maxTopInset = max(safeAreaTopInset, 40) + 4
            if abs(b.maxY - screenBounds.maxY) <= 4,
               b.minY >= screenBounds.minY - 4, b.minY <= screenBounds.minY + maxTopInset,
               b.height >= screenBounds.height - (maxTopInset + 10) { return true }
        }
        return false
    }

    static func isFullScreenAppFrontmost(on screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              // Finder's desktop window spans every display and is not a full-screen app.
              front.bundleIdentifier != "com.apple.finder",
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // AppKit's origin is the primary display's bottom-left; CoreGraphics' is its top-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let bounds = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                            width: screen.frame.width, height: screen.frame.height)
        let windows: [Window] = list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            return (pid, layer, rect)
        }
        return isFullScreen(screenBounds: bounds, frontmostPID: front.processIdentifier, windows: windows,
                            safeAreaTopInset: screen.safeAreaInsets.top)
    }
}
