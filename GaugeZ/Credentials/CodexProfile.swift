import Foundation

/// Finder does not inherit a shell's `CODEX_HOME`. Discover the same directory convention as
/// Claude, keeping each account's credentials and activity together.
struct CodexProfile: Equatable, Hashable, Sendable {
    let provider: ProviderID
    let directory: URL

    init(provider: ProviderID = .codex, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        precondition(provider.kind == .codex)
        self.provider = provider
        if provider.profileSlug == nil, let custom = environment["CODEX_HOME"], !custom.isEmpty {
            directory = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            directory = home.appendingPathComponent(provider.profileSlug.map { ".codex-\($0)" } ?? ".codex")
        }
    }

    var slug: String? { provider.profileSlug }
    var authURL: URL { directory.appendingPathComponent("auth.json") }
    var signInGuidance: String {
        if let slug = provider.profileSlug {
            return String(localized: "Sign in with CODEX_HOME pointing to ~/.codex-\(slug), then retry.", bundle: .language)
        }
        return String(localized: "The Codex CLI is not signed in to ChatGPT. Run `codex login`, or install the Codex app.", bundle: .language)
    }

    /// A signed-out profile can still have settings or sessions. Keep its row so it can
    /// explain how to sign that account back in.
    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> [CodexProfile] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        let markers = ["auth.json", "config.toml", "sessions", "history.jsonl", "state_5.sqlite", "sqlite/codex-dev.db"]
        let extras = names.compactMap { name -> CodexProfile? in
            guard name.hasPrefix(".codex-"),
                  let provider = ProviderID(rawValue: String(name.dropFirst())) else { return nil }
            let profile = CodexProfile(provider: provider, home: home, environment: [:])
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: profile.directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  markers.contains(where: { fm.fileExists(atPath: profile.directory.appendingPathComponent($0).path) })
            else { return nil }
            return profile
        }.sorted { $0.provider.rawValue < $1.provider.rawValue }
        return [CodexProfile(home: home, environment: environment)] + extras
    }
}
