import Foundation

/// A timeout releases the caller even if a provider ignores cancellation. A task group cannot
/// do this: it waits for all children before returning. Late results lose the completion race.
enum RefreshDeadline {
    static func run<Value: Sendable>(timeout: Duration,
                                    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let race = CompletionRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.attach(continuation)
                let worker = Task {
                    do {
                        try Task.checkCancellation()
                        race.finish(.success(try await operation()))
                    } catch { race.finish(.failure(error)) }
                }
                let timer = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    race.finish(.failure(URLError(.timedOut)))
                }
                race.hold(worker, timer)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

private final class CompletionRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        let completed: Result<Value, Error>? = lock.withLock { () -> Result<Value, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil as Result<Value, Error>?
        }
        if let completed { continuation.resume(with: completed) }
    }

    func hold(_ worker: Task<Void, Never>, _ timer: Task<Void, Never>) {
        let completed = lock.withLock {
            if result != nil { return true }
            tasks = [worker, timer]
            return false
        }
        if completed { worker.cancel(); timer.cancel() }
    }

    func finish(_ result: Result<Value, Error>) {
        let pending: (CheckedContinuation<Value, Error>?, [Task<Void, Never>]) = lock.withLock {
            guard self.result == nil else { return (nil, []) }
            self.result = result
            let pending = (continuation, tasks)
            continuation = nil
            tasks = []
            return pending
        }
        for task in pending.1 { task.cancel() }
        pending.0?.resume(with: result)
    }
}
