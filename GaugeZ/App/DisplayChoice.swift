import AppKit
import CoreGraphics

/// The display's own notch, the camera housing on a MacBook. Pixels there are behind a hole, not
/// merely covered, so nothing is ever drawn in it; the rail only hangs beneath it.
struct HardwareNotch: Equatable {
    let width: CGFloat
    let height: CGFloat
}

extension NSScreen {
    /// Measured from the two menu-bar strips either side of the notch, the only thing AppKit
    /// describes directly; a display without a notch reports no auxiliary areas.
    var hardwareNotch: HardwareNotch? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let width = frame.width - left.width - right.width
        let height = safeAreaInsets.top
        guard width > 0, height > 0 else { return nil }
        return HardwareNotch(width: width, height: height)
    }
}

struct DisplayChoice: Identifiable {
    let id: String
    let name: String

    static func identifier(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return screen.localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func current() -> [DisplayChoice] {
        [DisplayChoice(id: "main", name: "Main display"), DisplayChoice(id: "all", name: "All displays")] + NSScreen.screens.map {
            DisplayChoice(id: identifier(for: $0), name: $0.localizedName)
        }
    }
}
