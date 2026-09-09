import Foundation

/// One attempt per expiring credential, with a cooldown across rotations.
actor ClaudeTokenRenewal {
    private var attemptedExpiry: Date?
    private var lastAttempt: Date?
    private var running = false

    func renew(expiry: Date?, profile: ClaudeProfile, now: Date = .now,
               launch: @Sendable (ClaudeProfile) async throws -> Void = { try await ClaudeRenewalProcess.run($0) }) async -> Bool {
        guard !running, let expiry, expiry.timeIntervalSince(now) < 240,
              expiry != attemptedExpiry,
              now.timeIntervalSince(lastAttempt ?? .distantPast) >= 600 else { return false }
        running = true
        attemptedExpiry = expiry
        lastAttempt = now
        defer { running = false }
        do { try await launch(profile); try Task.checkCancellation(); return true }
        catch { return false }
    }
}

/// The standalone CLI owns renewal. Empty stdin supplies no conversation prompt.
/// This is a compatibility mechanism; callers verify the new credential's expiry.
enum ClaudeRenewalProcess {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids: Set<Int32> = []

    static func contains(_ pid: Int32) -> Bool { lock.withLock { pids.contains(pid) } }

    static func executable() -> URL? {
        for path in ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
            guard !url.path.contains("/Library/Application Support/Claude/"),
                  FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            return url
        }
        return nil
    }

    static func run(_ profile: ClaudeProfile) async throws {
        try Task.checkCancellation()
        guard let cli = executable() else { throw ClaudeProviderError.tokenExpired }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["-p"]
        // Run away from the user's project. Do not inherit API-key auth or nested-session flags.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDECODE", "CLAUDE_CODE_OAUTH_TOKEN"] {
            environment[key] = nil
        }
        // The default profile must run without CLAUDE_CONFIG_DIR: setting it makes the CLI
        // look for the hashed Keychain item, which the default sign-in does not use.
        environment["CLAUDE_CONFIG_DIR"] = profile.provider.profileSlug == nil ? nil : profile.directory.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try lock.withLock {
            try process.run()
            _ = pids.insert(process.processIdentifier)
        }
        defer { _ = lock.withLock { pids.remove(process.processIdentifier) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while process.isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            process.terminate()
            // A cancelled caller must still give the process a bounded grace period.
            await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw CancellationError()
        }
        try Task.checkCancellation()
        // A nonzero exit is expected for empty input; the credential after-check decides success.
    }
}
