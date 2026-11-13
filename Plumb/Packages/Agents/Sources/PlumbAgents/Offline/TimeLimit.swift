import Foundation

/// How a piece of work that was given a time limit ended.
enum Timed<Value: Sendable>: Sendable {
    case finished(Value)
    case failed(any Error)
    /// The limit passed first. The work was cancelled and its result, if any ever comes, dropped.
    case overran
}

/// Runs `work` and waits for it no longer than `limit`.
///
/// Returns at the limit even when the work ignores cancellation, so a stuck model or recognizer can
/// never hold up an answer. If the caller is cancelled, the work is cancelled and this returns
/// `.failed` with a `CancellationError`.
func runTimed<Value: Sendable>(within limit: Duration,
                               _ work: @escaping @Sendable () async throws -> Value) async -> Timed<Value> {
    let (events, feed) = AsyncStream<Timed<Value>>.makeStream()
    let runner = Task {
        do {
            feed.yield(.finished(try await work()))
        } catch {
            feed.yield(.failed(error))
        }
    }
    let timer = Task {
        do {
            try await Task.sleep(for: limit)
            feed.yield(.overran)
        } catch {
            // Cancelled because the work ended first.
        }
    }
    let first = await withTaskCancellationHandler {
        await events.first { _ in true }
    } onCancel: {
        runner.cancel()
        feed.finish()
    }
    timer.cancel()
    feed.finish()
    switch first {
    case .finished(let value):
        return .finished(value)
    case .failed(let error):
        return .failed(error)
    case .overran:
        runner.cancel()
        return .overran
    case nil:
        runner.cancel()
        return .failed(CancellationError())
    }
}
