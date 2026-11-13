import Foundation

/// What a recognizer has heard so far, shared between its callback thread and the code waiting for
/// the last word.
final class HeardText: @unchecked Sendable {
    private let lock = NSLock()
    private var heard = ""
    private var done = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// The words heard, trimmed. Nil when nothing was heard.
    var text: String? {
        let words = lock.withLock { heard }.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// Adds a finished piece to the end, for recognizers that hand over one final piece at a time.
    func append(_ piece: String) {
        let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        lock.withLock {
            guard !done else { return }
            heard = heard.isEmpty ? piece : heard + " " + piece
        }
    }

    /// Replaces everything heard, for recognizers that hand over the whole text each time.
    func replace(with whole: String) {
        lock.withLock {
            guard !done else { return }
            heard = whole
        }
    }

    /// Nothing more is coming. Wakes everyone waiting.
    func finish() {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            done = true
            defer { waiters = [] }
            return waiters
        }
        woken.forEach { $0.resume() }
    }

    /// Returns once `finish()` has been called.
    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            let finished = lock.withLock { () -> Bool in
                if done { return true }
                waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }
}
