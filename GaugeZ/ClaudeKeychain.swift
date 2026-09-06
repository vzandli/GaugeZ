import Foundation
import Security

/// Metadata and a reference to the exact item are read together, without requesting its secret.
enum ClaudeKeychain {
    struct Match: Equatable, Sendable {
        let modifiedAt: Date?
        let persistentRef: Data
    }

    static func newest(service: String) throws -> Match? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ClaudeProviderError.keychainDenied(status) }
        let items = result as? [[String: Any]] ?? (result as? [String: Any]).map { [$0] } ?? []
        return newest(in: items.compactMap { item in
            guard let ref = item[kSecValuePersistentRef as String] as? Data else { return nil }
            return Match(modifiedAt: item[kSecAttrModificationDate as String] as? Date, persistentRef: ref)
        })
    }

    static func newest(in matches: [Match]) -> Match? {
        matches.max {
            let left = $0.modifiedAt ?? .distantPast
            let right = $1.modifiedAt ?? .distantPast
            return left == right ? $0.persistentRef.lexicographicallyPrecedes($1.persistentRef) : left < right
        }
    }

    static func read(_ match: Match) throws -> Data {
        let query: [String: Any] = [
            kSecValuePersistentRef as String: match.persistentRef,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw ClaudeProviderError.notSignedIn }
        guard status == errSecSuccess else { throw ClaudeProviderError.keychainDenied(status) }
        guard let data = result as? Data, !data.isEmpty else { throw ClaudeProviderError.malformedCredential }
        return data
    }
}

/// One memory-only cache per profile. A refusal is retried only after the item changes or
/// an explicit user retry. Rotation is detected even when the previously read token is valid.
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
        lock.lock()
        if generation == currentGeneration {
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
