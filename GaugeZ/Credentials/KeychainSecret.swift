import Foundation
import Security

/// Permission for one Keychain read to show the password dialogue.
///
/// Granted only by Retry / Allow access. Spent by the read it is taken for,
/// whatever that read's outcome — a Deny that left it standing would hand the
/// next poll a dialogue. It also lapses: if the click never reached the Keychain,
/// a later poll must not spend it.
final class PromptPermission: @unchecked Sendable {
    static let window: TimeInterval = 60

    private let now: () -> Date
    private var owedUntil: Date?
    private let lock = NSLock()

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func grant() {
        lock.lock()
        owedUntil = now().addingTimeInterval(Self.window)
        lock.unlock()
    }

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = owedUntil else { return false }
        owedUntil = nil
        return now() < until
    }
}

/// Process-wide grant for the next Claude Keychain secret read.
enum KeychainAccess {
    static let permission = PromptPermission()

    static func grantInteractiveRead() { permission.grant() }
    static func consumeInteractive() -> Bool { permission.take() }
}

/// Reads a borrowed Keychain secret without raising the dialogue from a background refresh.
///
/// Claude Code files its item through `/usr/bin/security`. An item created that way admits
/// only Apple's own tools in its partition list, so Always Allow (which writes the access
/// list) buys exactly one read. Background polls disable interaction and, on refusal, retry
/// through the `security` tool — the one reader that item always admits. Items other apps
/// wrote themselves get no rescue: `security` is not on their list and would prompt.
enum KeychainSecret {
    /// One switch for the whole process. Two readers interleaving save/restore could otherwise
    /// leave interaction off, and Retry would never show its dialogue.
    private static let interactionLock = NSLock()

    /// Test hooks. Production never sets these.
    static var copyMatchingForTesting: (([String: Any], Bool) -> (OSStatus, Data?))?
    static var rescueForTesting: ((String, String?) -> Data?)?

    static func read(query: [String: Any], interactive: Bool,
                     rescue: (service: String, account: String?)?) -> (status: OSStatus, data: Data?) {
        interactionLock.lock()
        defer { interactionLock.unlock() }

        if let copyMatchingForTesting {
            let result = copyMatchingForTesting(query, interactive)
            return rescueIfNeeded(result, interactive: interactive, rescue: rescue)
        }

        var wasAllowed: DarwinBoolean = true
        if !interactive {
            SecKeychainGetUserInteractionAllowed(&wasAllowed)
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) } }

        var query = query
        if !interactive { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return rescueIfNeeded((status, item as? Data), interactive: interactive, rescue: rescue)
    }

    private static func rescueIfNeeded(_ result: (status: OSStatus, data: Data?),
                                       interactive: Bool,
                                       rescue: (service: String, account: String?)?) -> (status: OSStatus, data: Data?) {
        if !interactive, ClaudeKeychain.wasRefused(result.status), let rescue,
           let rescued = (rescueForTesting?(rescue.service, rescue.account)
                          ?? viaSecurityTool(service: rescue.service, account: rescue.account)) {
            return (errSecSuccess, rescued)
        }
        return result
    }

    /// `/usr/bin/security` is Apple-signed and is how these items were written, so it is on
    /// their access list. The secret comes back into this process; nothing is written or logged.
    static func viaSecurityTool(service: String, account: String?) -> Data? {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password"]
        if let account, !account.isEmpty {
            arguments += ["-a", account]
        }
        arguments += ["-s", service, "-w"]
        tool.arguments = arguments
        let out = Pipe()
        tool.standardOutput = out
        tool.standardError = FileHandle.nullDevice
        do {
            try tool.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { return nil }
        var trimmed = data
        while trimmed.last == 0x0A || trimmed.last == 0x0D { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }
}
