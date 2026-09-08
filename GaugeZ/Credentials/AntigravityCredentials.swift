import Foundation

/// The OAuth token Antigravity holds for a Google account.
///
/// Borrowed, like every other credential here — Antigravity signs in, this only
/// reads what it stored.
struct AntigravityCredentials {
    let accessToken: String
    let expiresAt: Date
    /// `consumer` for a personal Google account; enterprise installs differ.
    let authMethod: String

    var isExpired: Bool { expiresAt <= Date() }

    static let service = "gemini"
    static let account = "antigravity"

    private static let cache = ProviderSecretCache()
    static func forgetCached() { cache.forget() }
    static func load() throws -> AntigravityCredentials {
        let data = try cache.read(service: service, account: account, provider: "Antigravity")
        guard let credential = decode(data) else { throw SecretError.missing("Antigravity") }
        return credential
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
