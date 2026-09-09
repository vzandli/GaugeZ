import Foundation
import SQLite3

/// The OAuth token Antigravity holds for a Google account.
///
/// Borrowed, like every other credential here — Antigravity signs in, this only
/// reads what it stored.
struct AntigravityCredentials {
    let accessToken: String
    let expiresAt: Date
    /// `consumer` for a personal Google account; enterprise installs differ.
    let authMethod: String

    var projectId: String? = nil
    var email: String? = nil
    var isCLI: Bool = false

    var isExpired: Bool { expiresAt <= Date() }

    static let service = "gemini"
    static let account = "antigravity"

    private static let cache = ProviderSecretCache()
    static func forgetCached() { cache.forget() }
    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     keychain: () throws -> Data = { try cache.read(service: service, account: account, provider: "Antigravity") }) throws -> AntigravityCredentials {
        var held: AntigravityCredentials?
        var failure: Error = SecretError.missing("Antigravity")
        do {
            held = decode(try keychain())
            if let held, !held.isExpired { return held }
        } catch { failure = error }
        // Re-read local files each poll so CLI token rotation and WAL updates are visible.
        let candidates = [readOMP(home.appendingPathComponent(".omp/agent/agent.db")),
                          readJSON(home.appendingPathComponent(".gemini/oauth_creds.json"))].compactMap { $0 }
        if let current = candidates.first(where: { !$0.isExpired }) { return current }
        if let expired = held ?? candidates.first { return expired }
        throw failure
    }

    private static func readJSON(_ url: URL) -> AntigravityCredentials? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 1_048_576, let data = try? Data(contentsOf: url) else { return nil }
        return decodeCLI(data, omp: false)
    }

    private static func readOMP(_ url: URL) -> AntigravityCredentials? {
        guard let db = ReadOnlySQLite.open(path: url.path) else { return nil }
        defer { sqlite3_close(db) }
        let rows = ReadOnlySQLite.rows(in: db,
            sql: "SELECT data FROM auth_credentials WHERE provider = 'google-antigravity' ORDER BY updated_at DESC LIMIT 1", columns: 1)
        guard let text = rows.first?.first, text.utf8.count < 1_048_576 else { return nil }
        return decodeCLI(Data(text.utf8), omp: true)
    }

    static func decodeCLI(_ data: Data, omp: Bool) -> AntigravityCredentials? {
        struct Payload: Decodable {
            let access: String?
            let access_token: String?
            let expires: Double?
            let expiry_date: Double?
            let projectId: String?
            let email: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let token = omp ? payload.access : payload.access_token,
              !token.isEmpty, !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let millis = omp ? payload.expires : payload.expiry_date,
              millis.isFinite, millis > 0, millis < 253_402_300_800_000 else { return nil }
        return AntigravityCredentials(accessToken: token, expiresAt: Date(timeIntervalSince1970: millis / 1000),
                                      authMethod: "consumer", projectId: payload.projectId, email: payload.email, isCLI: true)
    }

    /// Split out so the decoding can be tested against a real stored value
    /// without a keychain.
    private static let goKeyringPrefix = "go-keyring-base64:"

    static func decode(_ data: Data) -> AntigravityCredentials? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix(goKeyringPrefix) {
            text = String(text.dropFirst(goKeyringPrefix.count))
        }
        guard let payload = Data(base64Encoded: text) else { return nil }

        struct Stored: Decodable {
            struct Token: Decodable {
                let access_token: String
                /// RFC 3339 with fractional seconds *and an offset* —
                /// "2026-08-31T21:53:49.575961+07:00". Not UTC, and not
                /// milliseconds since the epoch like Claude's. Parsing it as
                /// either is how a token that is live reads as long expired.
                let expiry: String
            }
            let auth_method: String
            let token: Token
        }

        guard let stored = try? JSONDecoder().decode(Stored.self, from: payload),
              let expiry = parse(stored.token.expiry)
        else { return nil }

        return AntigravityCredentials(accessToken: stored.token.access_token,
                                      expiresAt: expiry,
                                      authMethod: stored.auth_method)
    }

    /// Fractional seconds are not optional in this field, but a formatter that
    /// demands them fails on a whole-second timestamp — so try both.
    static func parse(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
