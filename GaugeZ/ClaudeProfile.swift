import CryptoKit
import Foundation

struct ClaudeProfile: Hashable, Sendable {
    let provider: ProviderID
    let directory: URL

    init(provider: ProviderID = .claude, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        precondition(provider.kind == .claude)
        self.provider = provider
        directory = home.appendingPathComponent(provider.profileSlug.map { ".claude-\($0)" } ?? ".claude")
    }

    var keychainService: String {
        guard provider.profileSlug != nil else { return "Claude Code-credentials" }
        let path = directory.standardizedFileURL.path
        let suffix = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(suffix)"
    }

    var sessionsDirectory: URL { directory.appendingPathComponent("sessions") }
    var credentialsFile: URL { directory.appendingPathComponent(".credentials.json") }
    var signInGuidance: String {
        if let slug = provider.profileSlug {
            return "Open Claude Code with CLAUDE_CONFIG_DIR pointing to ~/.claude-\(slug), sign in, then retry."
        }
        return "Open Claude Code and sign in, then retry."
    }

    /// Finder does not inherit shell aliases. Discover the conventional directories at launch,
    /// using only first-run file names; discovery never reads tokens or session contents.
    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ClaudeProfile] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        let markers = ["sessions", "projects", "settings.json", "history.jsonl", ".claude.json"]
        let extras = names.sorted().compactMap { name -> ClaudeProfile? in
            guard name.hasPrefix(".claude-"),
                  let provider = ProviderID(rawValue: String(name.dropFirst())) else { return nil }
            let profile = ClaudeProfile(provider: provider, home: home)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: profile.directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  markers.contains(where: { fm.fileExists(atPath: profile.directory.appendingPathComponent($0).path) })
            else { return nil }
            return profile
        }
        return [ClaudeProfile(home: home)] + extras
    }
}
