import Foundation

actor GLMUsageProvider: UsageProviding {
    private let session: URLSession
    private let retryPolicy: ProviderRetryPolicy
    private let loadCredentials: @Sendable () -> GLMCredentials.Credential?

    init(session: URLSession? = nil, retryPolicy: ProviderRetryPolicy? = nil,
         loadCredentials: @escaping @Sendable () -> GLMCredentials.Credential? = { GLMCredentials.load() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: configuration)
        self.loadCredentials = loadCredentials
        self.retryPolicy = retryPolicy ?? ProviderRetryPolicy(provider: .glm)
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        try retryPolicy.check()
        guard let credential = loadCredentials() else { throw GLMProviderError.notSignedIn }
        var request = URLRequest(url: credential.baseURL.appendingPathComponent("api/monitor/usage/quota/limit"))
        request.setValue(credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GLMProviderError.malformed }
        if http.statusCode == 429 { throw retryPolicy.throttled(response: http) }
        if http.statusCode == 401 || http.statusCode == 403 { throw GLMProviderError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw GLMProviderError.server(http.statusCode) }
        do {
            let parsed = try GLMUsageParser.parse(data)
            retryPolicy.succeeded()
            return UsageSnapshot(provider: .glm, accountID: nil,
                                 planName: parsed.plan.map { "GLM \($0.capitalized)" },
                                 windows: parsed.windows, observedAt: .now,
                                 source: "\(credential.source) · \(credential.baseURL.host ?? "Z.ai") Coding Plan",
                                 health: .live)
        } catch GLMProviderError.rateLimited {
            // The service also sends errors inside HTTP 200 envelopes.
            throw retryPolicy.throttled(response: http)
        }
    }
}

enum GLMUsageParser {
    struct Payload {
        let plan: String?
        let windows: [UsageWindow]
    }

    static func parse(_ data: Data) throws -> Payload {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GLMProviderError.malformed
        }
        let code = (object["code"] as? NSNumber)?.intValue
        if code == 401 || code == 403 { throw GLMProviderError.unauthorized }
        if code == 429 { throw GLMProviderError.rateLimited }
        guard (code == nil || code == 200), (object["success"] as? Bool) != false,
              let payload = object["data"] as? [String: Any],
              let limits = payload["limits"] as? [[String: Any]] else { throw GLMProviderError.malformed }
        var windows: [UsageWindow] = []
        for (index, limit) in limits.enumerated() {
            guard let percentage = (limit["percentage"] as? NSNumber)?.doubleValue else { continue }
            guard percentage.isFinite, percentage >= 0, percentage <= 100.5 else { throw GLMProviderError.malformed }
            let type = limit["type"] as? String ?? ""
            let unit = (limit["unit"] as? NSNumber)?.intValue
            let number = (limit["number"] as? NSNumber)?.intValue
            let descriptor: (String, String, Int?)
            if type == "TIME_LIMIT" {
                descriptor = ("mcp", "Monthly MCP calls", nil)
            } else if unit == 3, number == 5 {
                descriptor = ("session", "5-hour limit", 300)
            } else if unit == 6, number == 1 {
                descriptor = ("weekly", "Weekly limit", 10080)
            } else if let unit, let number, number > 0, number < 10000 {
                descriptor = ("window-\(unit)x\(number)", "Usage (\(number) \(unit == 3 ? "hours" : unit == 6 ? "weeks" : "units"))", nil)
            } else {
                // A window shape this build does not know is still a reading; dropping it (or
                // failing the whole response) would blank the ring the day Z.ai adds one.
                let base = type.isEmpty ? "limit" : type.lowercased()
                descriptor = ("\(base)-\(index)", "Usage", nil)
            }
            var reset: Date?
            if let millis = (limit["nextResetTime"] as? NSNumber)?.doubleValue {
                guard millis.isFinite, millis > 0, millis < 253_402_300_800_000 else { throw GLMProviderError.malformed }
                reset = Date(timeIntervalSince1970: millis / 1000)
            }
            guard !windows.contains(where: { $0.id == descriptor.0 }) else { throw GLMProviderError.malformed }
            windows.append(UsageWindow(id: descriptor.0, label: descriptor.1,
                                       usedPercent: min(100, percentage), resetsAt: reset,
                                       durationMinutes: descriptor.2))
        }
        guard !windows.isEmpty else { throw GLMProviderError.noLimits }
        let order = ["session", "weekly", "mcp"]
        windows.sort {
            let left = order.firstIndex(of: $0.id) ?? 3
            let right = order.firstIndex(of: $1.id) ?? 3
            return left == right ? $0.id < $1.id : left < right
        }
        return Payload(plan: payload["level"] as? String, windows: windows)
    }
}

enum GLMProviderError: LocalizedError, ProviderHealthDescribing {
    case notSignedIn, unauthorized, malformed, noLimits, rateLimited, server(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "No readable Z.ai Coding Plan key found. Configure it in Claude Code, ZCode, or OpenCode, then retry."
        case .unauthorized: "Z.ai rejected the Coding Plan key. Update it in the tool that owns it, then retry."
        case .malformed: "Z.ai returned an unsupported usage response."
        case .noLimits: "Z.ai reported no supported quota windows."
        case .rateLimited: "Z.ai asked GaugeZ to wait before checking again."
        case .server(let code): "Z.ai returned an error (\(code))."
        }
    }

    var providerHealth: ProviderHealth {
        let message = errorDescription ?? "GLM unavailable"
        switch self {
        case .notSignedIn, .unauthorized: return .signedOut(message)
        case .rateLimited, .server: return .stale(message)
        case .malformed, .noLimits: return .unavailable(message)
        }
    }
}
