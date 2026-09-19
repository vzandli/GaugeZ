import Foundation
import Security

/// An API key the user pasted into Settings. The only credentials GaugeZ owns rather than
/// borrows: each lives in the login keychain under a service no other app uses, so reading
/// it back never prompts, and removing it in Settings deletes the item.
struct OwnedAPIKey: Sendable {
    let provider: ProviderID
    /// Checked first, so a shell that already exports a key needs no setup.
    let environmentKey: String?

    static let ollama = OwnedAPIKey(provider: .ollama, environmentKey: "OLLAMA_API_KEY")
    static let minimax = OwnedAPIKey(provider: .minimax, environmentKey: "MINIMAX_API_KEY")

    static func key(for provider: ProviderID) -> OwnedAPIKey? {
        switch provider.kind {
        case .ollama: .ollama
        case .minimax: .minimax
        default: nil
        }
    }

    private var service: String { "com.vzyork.GaugeZ.apikey.\(provider.rawValue)" }
    private static let account = "GaugeZ"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let environmentKey, let value = Self.headerSafe(environment[environmentKey]) { return value }
        return stored()
    }

    /// The pasted key only, ignoring the environment: what Settings shows as saved.
    func stored() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return Self.headerSafe(String(data: data, encoding: .utf8))
    }

    var hasStoredKey: Bool { stored() != nil }

    @discardableResult
    func store(_ key: String) -> Bool {
        guard let key = Self.headerSafe(key) else { return false }
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Non-empty, single-line strings only: a key with a line break would be a header injection.
    static func headerSafe(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.rangeOfCharacter(from: .newlines) == nil, text.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return text
    }
}
