import Foundation
import PlumbContracts

/// The one thing a model may ask about the rescue: the latest measured numbers, with their age.
///
/// The numbers come from a closure the app supplies. Before they reach a model they are cut down to
/// what is trusted right now, so a model has nothing stale or untrusted to repeat.
public struct GetCPRQuality: AgentTool {
    /// The name the model calls this tool by.
    public static let name = "get_cpr_quality"

    /// This tool takes no arguments.
    public struct Input: Codable, Sendable {
        /// Creates the empty input.
        public init() {}
    }

    /// The digest of measurements, with untrusted values removed.
    public typealias Output = WorldDigest

    /// How long reading the measurements may take.
    public let deadline: Duration
    private let read: @Sendable () async -> WorldDigest

    /// - Parameter read: returns the app's current digest of the measurements.
    public init(deadline: Duration = AgentsConfig().toolDeadline,
                read: @escaping @Sendable () async -> WorldDigest) {
        self.deadline = deadline
        self.read = read
    }

    /// Reads the app's digest and returns the part of it a model may see.
    public func run(_ input: Input) async throws -> WorldDigest {
        Self.speakable(await read())
    }

    /// The digest as a model may see it: untrusted values removed, the rest rounded to what can be
    /// said aloud, so the model never has to round or choose for itself.
    static func speakable(_ digest: WorldDigest) -> WorldDigest {
        var out = digest
        out.ageS = (digest.ageS * 10).rounded() / 10
        out.pauseSeconds = (digest.pauseSeconds * 10).rounded() / 10
        out.handsOnFraction = digest.handsOnFraction.map { ($0 * 100).rounded() / 100 }
        out.ratePerMin = digest.ratePerMin.map { $0.rounded() }
        out.depthMM = digest.depthMM.map { $0.rounded() }
        out.depthSpreadMM = digest.depthSpreadMM.map { $0.rounded() }

        let rateTrusted = !digest.stale && digest.lock != .lost
        let depthTrusted = !digest.stale && digest.lock == .locked
        if !rateTrusted {
            out.ratePerMin = nil
            out.handsOnFraction = nil
        }
        if !depthTrusted {
            out.depthMM = nil
            out.depthSpreadMM = nil
        }
        return out
    }
}

extension WorldDigest: SpanSummarising {
    /// States the numbers and their age, or says that the numbers are stale.
    public var spanSummary: String {
        let age = ageS.oneDecimal
        if stale {
            return "The numbers are stale, last measured \(age) seconds ago, so the hands cannot be seen right now."
        }
        var facts = ["\(count) compressions"]
        facts.append(ratePerMin.map { "\(Int($0.rounded())) per minute" } ?? "rate not measured")
        facts.append(depthMM.map { "\(Int($0.rounded())) mm deep" } ?? "depth not trusted")
        if isPaused {
            facts.append("paused for \(pauseSeconds.oneDecimal) seconds")
        }
        return facts.joined(separator: ", ") + ", measured \(age) seconds ago."
    }
}
