import Foundation
import ObjectiveC
import SwiftUI

/// All supported languages in GaugeZ.
/// Defaults to `.system` to automatically match macOS system language preferences.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case en = "en"
    case ar = "ar"
    case bn = "bn"
    case bs = "bs"
    case de = "de"
    case es = "es"
    case fil = "fil"
    case fr = "fr"
    case hi = "hi"
    case it = "it"
    case ja = "ja"
    case ko = "ko"
    case mr = "mr"
    case ptBR = "pt-BR"
    case ru = "ru"
    case ta = "ta"
    case te = "te"
    case tr = "tr"
    case ur = "ur"
    case vi = "vi"
    case zhHans = "zh-Hans"
    case zhHK = "zh-HK"

    var id: String { rawValue }

    /// Native language name displayed in the Language picker menu.
    var displayName: String {
        switch self {
        case .system:
            String(localized: "System (Default)", bundle: .language)
        case .en:
            "English"
        case .ar:
            "العربية"
        case .bn:
            "বাংলা"
        case .bs:
            "Bosanski"
        case .de:
            "Deutsch"
        case .es:
            "Español"
        case .fil:
            "Filipino"
        case .fr:
            "Français"
        case .hi:
            "हिन्दी"
        case .it:
            "Italiano"
        case .ja:
            "日本語"
        case .ko:
            "한국어"
        case .mr:
            "मराठी"
        case .ptBR:
            "Português (Brasil)"
        case .ru:
            "Русский"
        case .ta:
            "தமிழ்"
        case .te:
            "తెలుగు"
        case .tr:
            "Türkçe"
        case .ur:
            "اردو"
        case .vi:
            "Tiếng Việt"
        case .zhHans:
            "简体中文"
        case .zhHK:
            "繁體中文 (香港)"
        }
    }

    /// The language macOS would give this app with no override: the user's global
    /// language list matched against the bundle's localizations. Read from the global
    /// domain rather than `Locale.preferredLanguages` because the app's own defaults may
    /// still carry a chosen language, and Foundation caches the launch-time answer either
    /// way, so choosing System after a restart would otherwise keep the old language.
    static func systemLanguageCode(
        preferred: [String] = systemPreferredLanguages,
        available: [String] = Bundle.main.localizations
    ) -> String? {
        Bundle.preferredLocalizations(from: available, forPreferences: preferred).first
    }

    static var systemPreferredLanguages: [String] {
        let value = CFPreferencesCopyValue(
            "AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        return (value as? [String]) ?? ["en"]
    }

    /// The resolved Locale for formatting and SwiftUI environment injection.
    var locale: Locale {
        switch self {
        case .system:
            // The process locale already speaks the system language unless a chosen
            // language was in force at launch; only then is it replaced.
            guard let code = Self.systemLanguageCode(),
                  Locale(identifier: code).language.minimalIdentifier != Locale.current.language.minimalIdentifier
            else { return Locale.autoupdatingCurrent }
            return Locale(identifier: code)
        case .ptBR:
            return Locale(identifier: "pt-BR")
        case .zhHans:
            return Locale(identifier: "zh-Hans")
        case .zhHK:
            return Locale(identifier: "zh-HK")
        default:
            return Locale(identifier: rawValue)
        }
    }

    /// The `.lproj` to read strings from. System resolves to a concrete language too, so a
    /// switch back to it takes effect at once instead of after the next launch.
    var bundleLanguageCode: String? {
        self == .system ? Self.systemLanguageCode() : rawValue
    }

    /// Returns the localized string for this language directly from its lproj bundle.
    func localizedString(_ key: String) -> String {
        guard let code = bundleLanguageCode,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

// MARK: - Dynamic Bundle Localization

private var bundleKey: UInt8 = 0

/// A Bundle subclass that forwards localizedString requests to the currently active language bundle.
final class LocalizedBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let bundle = objc_getAssociatedObject(self, &bundleKey) as? Bundle else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return bundle.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// The bundle strings are read from: the chosen language's `.lproj`, or the app bundle
    /// when the system language is in use. `String(localized:)` must be handed this
    /// explicitly; unlike `NSLocalizedString`, it does not go through the override below.
    static var language: Bundle {
        (objc_getAssociatedObject(Bundle.main, &bundleKey) as? Bundle) ?? Bundle.main
    }

    /// Sets the runtime localization override for Bundle.main.
    /// Pass nil to restore system default localization.
    static func setLanguage(_ languageCode: String?) {
        defer {
            object_setClass(Bundle.main, LocalizedBundle.self)
        }
        guard let languageCode,
              let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            objc_setAssociatedObject(Bundle.main, &bundleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        objc_setAssociatedObject(Bundle.main, &bundleKey, bundle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("GaugeZAppLanguageDidChange")
}
