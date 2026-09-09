import AppKit
import SwiftUI

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

    var titleKey: LocalizedStringKey {
        switch self {
        case .dock: "Dock"
        case .menuBar: "Menu bar"
        case .hidden: "Neither"
        }
    }

    var explanationKey: LocalizedStringKey {
        switch self {
        case .dock: "A Dock icon while GaugeZ is running, plus the menu bar item."
        case .menuBar: "A small icon in the menu bar, and nothing in the Dock."
        // Said here because choosing this removes every visible way back to these settings.
        case .hidden: "No icon anywhere. Open GaugeZ again from Applications or Spotlight to bring Settings back."
        }
    }

    var title: String {
        switch self {
        case .dock: String(localized: "Dock", bundle: .language)
        case .menuBar: String(localized: "Menu bar", bundle: .language)
        case .hidden: String(localized: "Neither", bundle: .language)
        }
    }

    var explanation: String {
        switch self {
        case .dock: String(localized: "A Dock icon while GaugeZ is running, plus the menu bar item.", bundle: .language)
        case .menuBar: String(localized: "A small icon in the menu bar, and nothing in the Dock.", bundle: .language)
        // Said here because choosing this removes every visible way back to these settings.
        case .hidden: String(localized: "No icon anywhere. Open GaugeZ again from Applications or Spotlight to bring Settings back.", bundle: .language)
        }
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        self == .dock ? .regular : .accessory
    }

    var wantsStatusItem: Bool { self != .hidden }
}
