import Foundation
import Security

/// Metadata and a reference to the exact item are read together, without requesting its secret.
enum ClaudeKeychain {
    /// `errSecInDarkWake` (-25320): the Mac has just woken and Security cannot show UI yet. It says
    /// nothing about the account or the grant, so it must never read as a refusal. Security exports
    /// no named constant for it.
    static let darkWakeStatus: OSStatus = -25320
    /// `errAuthorizationInternal` (-60008): macOS wanted a prompt and had no way to show one.
    static let authorizationInternalStatus: OSStatus = -60008

    /// A read that failed for a reason unrelated to the grant is transient; everything else is a
    /// refusal that automatic polling must not repeat.
    static func failure(for status: OSStatus) -> ClaudeProviderError {
        wasTransient(status) ? .keychainUnavailable(status) : .keychainDenied(status)
    }

    static func wasTransient(_ status: OSStatus) -> Bool {
        status == darkWakeStatus || status == authorizationInternalStatus
    }

    /// The item exists and this app was not let in. Distinct from "not found".
    static func wasRefused(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed
            || status == errSecUserCanceled
            || status == errSecInteractionNotAllowed
            || status == errSecInteractionRequired
    }

    struct Match: Equatable, Sendable {
        let modifiedAt: Date?
        let persistentRef: Data
        let service: String
        let account: String?

        init(modifiedAt: Date?, persistentRef: Data, service: String = "", account: String? = nil) {
            self.modifiedAt = modifiedAt
            self.persistentRef = persistentRef
            self.service = service
            self.account = account
        }
    }

    static func newest(service: String, account: String? = nil) throws -> Match? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(for: status) }
        let items = result as? [[String: Any]] ?? (result as? [String: Any]).map { [$0] } ?? []
        return newest(in: items.compactMap { item in
            guard let ref = item[kSecValuePersistentRef as String] as? Data else { return nil }
            return Match(
                modifiedAt: item[kSecAttrModificationDate as String] as? Date,
                persistentRef: ref,
                service: item[kSecAttrService as String] as? String ?? service,
                account: item[kSecAttrAccount as String] as? String ?? account
            )
        })
    }

    static func newest(in matches: [Match]) -> Match? {
        matches.max {
            let left = $0.modifiedAt ?? .distantPast
            let right = $1.modifiedAt ?? .distantPast
            return left == right ? $0.persistentRef.lexicographicallyPrecedes($1.persistentRef) : left < right
        }
    }

    static func read(_ match: Match, interactive: Bool? = nil) throws -> Data {
        let allowed = interactive ?? KeychainAccess.consumeInteractive()
        let rescue: (service: String, account: String?)? = match.service.isEmpty
            ? nil : (match.service, match.account)
        let (status, data) = KeychainSecret.read(
            query: [
                kSecClass as String: kSecClassGenericPassword,
                kSecValuePersistentRef as String: match.persistentRef,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ],
            interactive: allowed,
            rescue: rescue
        )
        if status == errSecItemNotFound { throw ClaudeProviderError.notSignedIn }
        guard status == errSecSuccess else { throw failure(for: status) }
        guard let data, !data.isEmpty else { throw ClaudeProviderError.malformedCredential }
        return data
    }
}

/// One memory-only cache per profile. A refusal is retried only after the item changes or
/// an explicit user retry. Rotation is detected even when the previously read token is valid.
/// A transient failure (the Keychain unavailable right after wake) is never recorded, so the
/// next poll simply tries again.
final class ClaudeCredentialCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp: ClaudeKeychain.Match?
    private var result: Result<ClaudeCredential, Error>?
    private var attemptedAt: Date?
    private var generation = UUID()

    func value(stamp current: ClaudeKeychain.Match?, now: Date = .now,
               reload: () throws -> ClaudeCredential) throws -> ClaudeCredential {
        lock.lock()
        let currentGeneration = generation
        if let result, current == stamp {
            let refused: Bool
            if case .failure(let error) = result, case .keychainDenied = error as? ClaudeProviderError {
                refused = true
            } else { refused = false }
            if current != nil || refused || now.timeIntervalSince(attemptedAt ?? .distantPast) < 300 {
                lock.unlock()
                return try result.get()
            }
        }
        lock.unlock()
        // A Keychain prompt must never hold the lock needed by UI-driven retry/forget.
        let fresh = Result { try reload() }
        var transient = false
        if case .failure(let error) = fresh, case .keychainUnavailable = error as? ClaudeProviderError {
            transient = true
        }
        lock.lock()
        if generation == currentGeneration, !transient {
            stamp = current
            attemptedAt = now
            result = fresh
        }
        lock.unlock()
        return try fresh.get()
    }

    func forget() {
        lock.lock()
        defer { lock.unlock() }
        generation = UUID()
        stamp = nil
        result = nil
        attemptedAt = nil
    }
}
