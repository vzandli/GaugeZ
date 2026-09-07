import AppKit

/// Where GaugeZ shows itself apart from the rail: a Dock tile, a menu bar item, or neither.
/// The rail is the product; this only decides how Settings and Quit are reached.
enum AppPresence: String, CaseIterable, Identifiable {
    /// A normal app: Dock tile, ⌘-Tab entry, and a menu bar item.
    case dock
    /// An icon in the menu bar and nothing in the Dock. The default.
    case menuBar
    /// Neither. Only the rail itself.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock: "Dock"
        case .menuBar: "Menu bar"
        case .hidden: "Neither"
        }
    }

    var explanation: String {
        switch self {
        case .dock: "A Dock icon while GaugeZ is running, plus the menu bar item."
        case .menuBar: "A small icon in the menu bar, and nothing in the Dock."
        // Said here because choosing this removes every visible way back to these settings.
        case .hidden: "No icon anywhere. Open GaugeZ again from Applications or Spotlight to bring Settings back."
        }
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        self == .dock ? .regular : .accessory
    }

    var wantsStatusItem: Bool { self != .hidden }
}
