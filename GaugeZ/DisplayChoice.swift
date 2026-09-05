import AppKit
import CoreGraphics

struct DisplayChoice: Identifiable {
    let id: String
    let name: String

    static func identifier(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return screen.localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func current() -> [DisplayChoice] {
        [DisplayChoice(id: "main", name: "Main display")] + NSScreen.screens.map {
            DisplayChoice(id: identifier(for: $0), name: $0.localizedName)
        }
    }
}
