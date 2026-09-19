// Adapted from Codenotch, Copyright (c) 2026 Vinz, MIT License.
// See ThirdPartyNotices.txt.
import Foundation

/// Reads Kiro's monthly credits by asking `kiro-cli chat --no-interactive /usage`.
///
/// kiro-cli owns the sign-in and its refresh. GaugeZ never mints, rotates or writes that session:
/// it runs one read-only command and parses the card the CLI prints. A CLI that says it is logged
/// out is reported as signed out, with the command that fixes it, rather than repaired here.
actor KiroUsageProvider: UsageProviding {
    private let retryPolicy: ProviderRetryPolicy
    /// Injected so tests never spawn whatever kiro-cli the developer happens to have installed.
    private let readUsage: @Sendable () throws -> String

    init(retryPolicy: ProviderRetryPolicy? = nil,
         readUsage: @escaping @Sendable () throws -> String = { try KiroCLI.usageOutput() }) {
        self.retryPolicy = retryPolicy ?? ProviderRetryPolicy(provider: .kiro)
        self.readUsage = readUsage
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        let work = readUsage
        // Draining a pipe blocks its thread; the actor must not sit behind that.
        let text = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
        try Task.checkCancellation()

        let reading = try KiroUsageParser.reading(from: text)
        retryPolicy.succeeded()
        return UsageSnapshot(
            provider: .kiro,
            accountID: nil,
            planName: reading.plan,
            windows: [reading.credits],
            observedAt: .now,
            source: String(localized: "Kiro CLI sign-in", bundle: .language),
            health: .live
        )
    }
}

// MARK: - The CLI

/// Locating and running kiro-cli. Nothing here reads a token: the binary already holds the
/// session, so GaugeZ needs no keychain access and no credential file of its own.
enum KiroCLI {
    /// Non-interactive chat with a single `/usage` prompt.
    static let arguments = ["chat", "--no-interactive", "/usage"]
    /// Long enough for a cold start, short enough that a wedged CLI cannot hold a refresh open.
    static let timeout: TimeInterval = 20

    /// Finder launches the app with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, which is not where
    /// kiro-cli installs itself, so the known locations are checked directly.
    static func locateBinary(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/kiro-cli"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/kiro-cli"),
                          URL(fileURLWithPath: "/usr/local/bin/kiro-cli")]
        return candidates.first { isRunnable($0.path) }
    }

    /// `isExecutableFile` is also true for directories, and a relative path would resolve against
    /// the app's working directory — which is how a planted binary gets run.
    private static func isRunnable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    static func usageOutput() throws -> String {
        guard let binary = locateBinary() else { throw KiroProviderError.notInstalled }
        return try run(binary: binary)
    }

    static func run(binary: URL, timeout: TimeInterval = timeout) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        // 2.x defaults to a TUI that drives the inherited tty and never returns; a dumb terminal
        // and the classic UI are what make `--no-interactive` actually non-interactive.
        environment["TERM"] = "dumb"
        environment["KIRO_CHAT_UI"] = "classic"

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        // Not the user's project: chat keys MCP and session files on the working directory.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // Never a terminal. Inheriting stdin leaves the CLI waiting for input that never comes.
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let stdout = output.fileHandleForReading, stderr = errors.fileHandleForReading
        let collected = Buffer(), collectedErrors = Buffer()
        // Both drained as they fill: an unread pipe blocks the CLI once its buffer is full.
        for (handle, buffer) in [(stdout, collected), (stderr, collectedErrors)] {
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { buffer.append(chunk) }
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
            exited.signal()
        }
        do { try process.run() } catch { throw KiroProviderError.notInstalled }
        let pid = process.processIdentifier
        // Its own group, so a timeout takes the CLI's children with it.
        let grouped = setpgid(pid, pid) == 0

        if exited.wait(timeout: .now() + timeout) != .success {
            if grouped { _ = killpg(pid, SIGKILL) }
            _ = kill(pid, SIGKILL)
            if process.isRunning { process.terminate() }
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
            // Children holding the write end keep the reaper blocked after a lone kill.
            try? stdout.close()
            try? stderr.close()
            _ = exited.wait(timeout: .now() + 1)
            throw KiroProviderError.timedOut
        }
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        collected.append(drain(stdout))
        collectedErrors.append(drain(stderr))

        let out = String(data: collected.value, encoding: .utf8) ?? ""
        let err = String(data: collectedErrors.value, encoding: .utf8) ?? ""
        // A non-zero exit is the CLI declining to answer, which in practice means no sign-in —
        // but its own words come first, so "not logged in" is not reported as a crash.
        guard process.terminationStatus == 0 else {
            if KiroUsageParser.mentionsSignedOut(out + "\n" + err) { throw KiroProviderError.notSignedIn }
            throw KiroProviderError.commandFailed(process.terminationStatus)
        }
        guard let text = usageText(stdout: out, stderr: err) else { throw KiroProviderError.noReading }
        return text
    }

    /// Older CLIs print the card to stdout, newer ones to stderr, and either stream may also
    /// carry stray warnings — so the one holding the card's heading wins.
    static func usageText(stdout: String, stderr: String) -> String? {
        let marker = "Estimated Usage"
        if stdout.contains(marker) { return stdout }
        if stderr.contains(marker) { return stderr }
        let said = stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stderr : stdout
        return said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : said
    }

    /// Leftovers after exit. `availableData` blocks while a child still holds the write end.
    private static func drain(_ handle: FileHandle) -> Data {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return Data() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            collected.append(contentsOf: buffer[0..<count])
        }
        return collected
    }

    /// Bytes handed over by the readability handler on another thread.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        func append(_ chunk: Data) { lock.lock(); stored.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return stored }
    }
}

// MARK: - Parsing

/// Parses the TUI card `/usage` prints: ANSI escapes, box drawing and a `█` bar.
///
/// Only the monthly credit pool is read. A plan name with no bar and no `(X of Y covered in plan)`
/// is a card with no meter — not a 0% to draw a ring from.
enum KiroUsageParser {
    struct Reading: Sendable {
        let plan: String?
        let credits: UsageWindow
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// The CLI says this in its own words rather than through an exit code.
    static func mentionsSignedOut(_ text: String) -> Bool {
        let lowered = stripANSI(text).lowercased(with: posix)
        return ["not logged in", "login required", "kiro-cli login", "oauth error",
                "failed to initialize auth portal"].contains { lowered.contains($0) }
    }

    static func reading(from text: String, now: Date = .now) throws -> Reading {
        let card = stripANSI(text)
        if mentionsSignedOut(card) { throw KiroProviderError.notSignedIn }

        // The bar wins over the credit pair: it is what the CLI itself rounds and prints.
        let pair = captures(in: card, pattern: #"\((\d+\.?\d*)\s+of\s+(\d+)\s+covered"#)
        let usedPercent: Double
        if let percent = double(in: card, pattern: #"█+\s*(\d+)%"#) {
            usedPercent = percent
        } else if pair.count == 2, let used = Double(pair[0]), let total = Double(pair[1]), total > 0 {
            usedPercent = used / total * 100
        } else {
            throw KiroProviderError.noReading
        }
        guard usedPercent.isFinite, usedPercent >= 0 else { throw KiroProviderError.noReading }

        let resetsAt = resetDate(in: card, now: now)
        return Reading(
            plan: planName(in: card).map(displayPlanName),
            credits: UsageWindow(
                id: "credits",
                label: String(localized: "Monthly limit", bundle: .language),
                usedPercent: min(100, usedPercent),
                resetsAt: resetsAt,
                durationMinutes: 43_200
            )
        )
    }

    /// `KIRO PRO` reads as a shout in a menu bar; names that never mention Kiro stay as printed.
    static func displayPlanName(_ raw: String) -> String {
        let trimmed = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        guard trimmed.range(of: "KIRO", options: [.caseInsensitive, .literal]) != nil else { return trimmed }
        return trimmed.split(separator: " ").map { word in
            String(word.prefix(1)).uppercased(with: posix) + String(word.dropFirst()).lowercased(with: posix)
        }.joined(separator: " ")
    }

    /// CSI, OSC, charset-select and two-byte C1 escapes.
    static func stripANSI(_ text: String) -> String {
        ansi.stringByReplacingMatches(in: text, options: [],
                                      range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static let ansi = try! NSRegularExpression(
        pattern: "\u{001B}\\[[0-9;:?]*[ -/]*[@-~]"
            + "|\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)"
            + "|\u{001B}[()][0-9A-Za-z]"
            + "|\u{001B}[@-Z\\\\^_]")

    /// `Plan:` is not at column 0 — box drawing wraps the line. Horizontal whitespace only, so
    /// a match cannot run into the next row of the card.
    private static func planName(in text: String) -> String? {
        let patterns = [
            #"Plan:[ \t]*([^|\r\n]+?)[ \t]*\|[ \t]*[0-9]+[ \t]+usage breakdowns?"#,
            #"\|[ \t]*(KIRO(?:[ \t]+[A-Za-z0-9+]+)+)"#,
            #"Plan:[ \t]*([^|\r\n]+)"#
        ]
        return patterns.lazy.compactMap { capture(in: text, pattern: $0) }.first { !$0.isEmpty }
    }

    /// `YYYY-MM-DD` as printed; `MM/DD` is this year while that day is still ahead, otherwise
    /// next — a January reset read in December belongs to next year. Compared on the start of
    /// the local day so a reset read *on* its date is not pushed a year out.
    private static func resetDate(in text: String, now: Date) -> Date? {
        guard let stamp = capture(in: text, pattern: #"resets on (\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2})"#)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = posix
        if stamp.contains("-") {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = posix
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: stamp)
        }
        let parts = stamp.split(separator: "/")
        guard parts.count == 2, let month = Int(parts[0]), (1...12).contains(month),
              let day = Int(parts[1]), (1...31).contains(day) else { return nil }
        let today = calendar.startOfDay(for: now)
        var components = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                        year: calendar.component(.year, from: today), month: month, day: day)
        if let date = calendar.date(from: components), date >= today { return date }
        components.year = (components.year ?? 0) + 1
        return calendar.date(from: components)
    }

    private static func double(in text: String, pattern: String) -> Double? {
        capture(in: text, pattern: pattern).flatMap(Double.init)
    }

    private static func capture(in text: String, pattern: String) -> String? {
        captures(in: text, pattern: pattern).first
    }

    private static func captures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, options: [],
                                           range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

enum KiroProviderError: LocalizedError, ProviderHealthDescribing {
    case notInstalled
    case notSignedIn
    case timedOut
    case commandFailed(Int32)
    case noReading

    var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "kiro-cli was not found. Install it, then retry.", bundle: .language)
        case .notSignedIn: String(localized: "Kiro is not signed in. Run kiro-cli login, then retry.", bundle: .language)
        case .timedOut: String(localized: "kiro-cli did not answer in time.", bundle: .language)
        case .commandFailed(let status): String(localized: "kiro-cli exited with status \(status).", bundle: .language)
        case .noReading: String(localized: "kiro-cli reported no credit usage.", bundle: .language)
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? String(localized: "Kiro unavailable", bundle: .language)
        switch self {
        case .notSignedIn: return .signedOut(message)
        case .timedOut: return .stale(message)
        case .notInstalled, .commandFailed, .noReading: return .unavailable(message)
        }
    }
}
