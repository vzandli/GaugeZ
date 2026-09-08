import Foundation
import Security

/// Memory-only secret cache. Metadata detects rotation without reopening a permission prompt.
final class ProviderSecretCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp: ClaudeKeychain.Match?
    private var result: Result<Data, Error>?
    private var generation = UUID()

    func read(service: String, account: String, provider: String) throws -> Data {
        let current: ClaudeKeychain.Match?
        do { current = try ClaudeKeychain.newest(service: service, account: account) }
        catch { throw SecretError.unavailable(provider) }
        lock.lock()
        let generation = self.generation
        if let result, stamp == current {
            lock.unlock()
            return try result.get()
        }
        lock.unlock()
        let fresh = Result<Data, Error> {
            guard let current else { throw SecretError.missing(provider) }
            do { return try ClaudeKeychain.read(current) }
            catch ClaudeProviderError.keychainUnavailable { throw SecretError.unavailable(provider) }
            catch ClaudeProviderError.keychainDenied { throw SecretError.denied(provider) }
            catch { throw SecretError.missing(provider) }
        }
        lock.lock()
        if self.generation == generation {
            if case .failure(SecretError.unavailable) = fresh { /* retry after wake */ }
            else { stamp = current; result = fresh }
        }
        lock.unlock()
        return try fresh.get()
    }

    func forget() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); stamp = nil; result = nil
    }
}

enum SecretError: LocalizedError, ProviderHealthDescribing {
    case missing(String), denied(String), unavailable(String)
    var errorDescription: String? {
        switch self {
        case .missing(let name): "No saved \(name) sign-in. Sign in with its app or CLI, then refresh."
        case .denied(let name): "Keychain access for \(name) was declined. Use Retry to request access again."
        case .unavailable(let name): "The Keychain is temporarily unavailable for \(name)."
        }
    }
    var providerHealth: ProviderHealth {
        switch self {
        case .missing: .signedOut(errorDescription!)
        case .denied: .permissionRequired(errorDescription!)
        case .unavailable: .stale(errorDescription!)
        }
    }
}
