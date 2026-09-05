import Foundation

actor CodexUsageProvider: UsageProviding {
    func fetchSnapshot() async throws -> UsageSnapshot {
        let probe = CodexAppServerProbe()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try probe.run()
            }.value
        } onCancel: {
            probe.cancel()
        }
    }
}

private final class CodexAppServerProbe: @unchecked Sendable {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)

    private var buffer = Data()
    private var completed = false
    private var result: Result<UsageSnapshot, Error>?
    private var stderr = Data()

    func cancel() { finish(.failure(CancellationError())) }

    func run() throws -> UsageSnapshot {
        let executable = try locateExecutable()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveError(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.processTerminated(status: process.terminationStatus)
        }

        do {
            try process.run()
            try send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "gaugez",
                        "title": "GaugeZ",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ])
        } catch {
            cleanup()
            throw error
        }

        let waitResult = completion.wait(timeout: .now() + 12)
        if waitResult == .timedOut {
            finish(.failure(CodexProviderError.timedOut))
        }

        cleanup()
        return try (result ?? .failure(CodexProviderError.noResponse)).get()
    }

    private func locateExecutable() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        ]
        if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return executable
        }
        throw CodexProviderError.notInstalled
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[..<newline])
            buffer.removeSubrange(...newline)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            handleLine(line)
        }
    }

    private func handleLine(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = (object["id"] as? NSNumber)?.intValue
        else { return }

        if id == 1 {
            do {
                try send(["method": "initialized"])
                try send([
                    "id": 2,
                    "method": "account/rateLimits/read",
                    "params": [:]
                ])
            } catch {
                finish(.failure(error))
            }
            return
        }

        guard id == 2 else { return }
        do {
            if let errorObject = object["error"] as? [String: Any] {
                let message = errorObject["message"] as? String ?? "Codex returned an unknown error"
                throw CodexProviderError.server(message)
            }
            let envelope = try JSONDecoder().decode(RateLimitEnvelope.self, from: data)
            guard let response = envelope.result else {
                throw CodexProviderError.malformedResponse
            }
            finish(.success(try makeSnapshot(from: response)))
        } catch {
            finish(.failure(error))
        }
    }

    private func makeSnapshot(from response: RateLimitResponse) throws -> UsageSnapshot {
        let buckets: [(String, RateLimitSnapshot)]
        if let byID = response.rateLimitsByLimitId, !byID.isEmpty {
            buckets = byID.sorted(by: { $0.key < $1.key })
        } else if let legacy = response.rateLimits {
            buckets = [(legacy.limitId ?? "codex", legacy)]
        } else {
            throw CodexProviderError.noUsageWindows
        }

        var windows: [UsageWindow] = []
        var planName: String?
        for (bucketID, bucket) in buckets {
            planName = planName ?? bucket.planType
            if let primary = bucket.primary {
                windows.append(try primary.normalized(id: "\(bucketID)-primary", fallbackLabel: "Current limit"))
            }
            if let secondary = bucket.secondary {
                windows.append(try secondary.normalized(id: "\(bucketID)-secondary", fallbackLabel: "Weekly limit"))
            }
        }

        guard !windows.isEmpty else { throw CodexProviderError.noUsageWindows }
        return UsageSnapshot(
            provider: .codex,
            accountID: response.accountId,
            planName: planName.map { "ChatGPT \($0.capitalized)" },
            windows: windows,
            observedAt: .now,
            source: "Codex app-server",
            health: .live
        )
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var framed = data
        framed.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: framed)
    }

    private func receiveError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if stderr.count < 8192 { stderr.append(data.prefix(8192 - stderr.count)) }
        lock.unlock()
    }

    private func processTerminated(status: Int32) {
        guard status != 0 else { return }
        lock.lock()
        let message = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        finish(.failure(CodexProviderError.server(message?.isEmpty == false ? message! : "App server exited with status \(status)")))
    }

    private func finish(_ newResult: Result<UsageSnapshot, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        result = newResult
        lock.unlock()
        completion.signal()
    }

    private func cleanup() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
        }
        try? inputPipe.fileHandleForWriting.close()
    }
}

private struct RateLimitEnvelope: Decodable {
    let result: RateLimitResponse?
}

private struct RateLimitResponse: Decodable {
    let accountId: String?
    let rateLimits: RateLimitSnapshot?
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

private struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let resetsAt: Int64?
    let windowDurationMins: Int?

    /// `fallbackLabel` names the window when the server omits its duration; out-of-range
    /// percentages are clamped rather than rejected so one odd bucket cannot fail the snapshot.
    func normalized(id: String, fallbackLabel: String) throws -> UsageWindow {
        guard windowDurationMins.map({ $0 > 0 }) ?? true else {
            throw CodexProviderError.malformedResponse
        }
        let label = windowDurationMins == nil ? fallbackLabel : durationLabel
        return UsageWindow(
            id: id,
            label: label,
            usedPercent: max(0, min(100, usedPercent)),
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            durationMinutes: windowDurationMins
        )
    }

    private var durationLabel: String {
        guard let minutes = windowDurationMins else { return "Current limit" }
        switch minutes {
        case 300: return "5-hour limit"
        case 10_080: return "Weekly limit"
        case let value where value % 1_440 == 0: return "\(value / 1_440)-day limit"
        case let value where value % 60 == 0: return "\(value / 60)-hour limit"
        default: return "\(minutes)-minute limit"
        }
    }
}

private enum CodexProviderError: LocalizedError, ProviderHealthDescribing {
    case notInstalled
    case timedOut
    case noResponse
    case malformedResponse
    case noUsageWindows
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: 
            return "ChatGPT/Codex is not installed."
        case .timedOut: 
            return "Codex did not answer within 12 seconds."
        case .noResponse: 
            return "Codex returned no response."
        case .malformedResponse: 
            return "Codex returned an unsupported response."
        case .noUsageWindows: 
            return "Codex reported no usage windows."
        case .server(let message):
            if message.contains("404") || message.contains("wham/usage") {
                return "ChatGPT rate limits are temporarily unavailable."
            } else if message.contains("401") || message.contains("token") || message.contains("auth") {
                return "ChatGPT session expired. Sign in inside ChatGPT to refresh."
            }
            return "Codex app-server could not provide usage. Open Codex and retry."
        }
    }

    var providerHealth: ProviderHealth {
        let text = errorDescription ?? "Codex error"
        switch self {
        case .server(let message) where message.contains("401") || message.contains("token") || message.contains("auth"):
            return .signedOut(text)
        case .server, .timedOut, .noResponse:
            return .stale(text)
        default:
            return .unavailable(text)
        }
    }
}
