import PlumbContracts

/// The part of one Metrics reading the rules are allowed to judge. Nil means "cannot be judged right now".
struct Sight: Equatable, Sendable {
    /// Typical depth in millimetres. Nil unless depth is fully trusted and compressions are under way.
    let depthMM: Double?
    /// Compressions per minute. Nil with no signal, with no rate yet, or too soon after a start or a pause.
    let ratePerMin: Double?

    init(metrics: Metrics, compressionsSincePause: Int, minCompressionsForRate: Int) {
        // During a pause the rolling numbers describe strokes that have stopped, so they are not judged.
        guard !metrics.isPaused else {
            depthMM = nil
            ratePerMin = nil
            return
        }
        depthMM = metrics.lock == .locked ? metrics.depthMM : nil
        let rhythmTrusted = metrics.lock != .lost && compressionsSincePause >= minCompressionsForRate
        ratePerMin = rhythmTrusted ? metrics.ratePerMin : nil
    }

    /// How this look compares with the targets. Stricter than the fault rules: the dead band earns no praise.
    ///
    /// Depth has no upper limit here because "too deep" cannot be measured well enough to judge.
    func quality(against targets: Targets) -> Quality {
        if let depthMM, depthMM < targets.depthMinMM { return .offTarget }
        if let ratePerMin, ratePerMin < targets.rateMinPerMin || ratePerMin > targets.rateMaxPerMin {
            return .offTarget
        }
        return depthMM != nil && ratePerMin != nil ? .onTarget : .unseen
    }
}

/// How one look compares with the targets, for deciding whether praise has been earned.
enum Quality: Equatable, Sendable {
    /// Depth and rate were both judged and both are inside the target.
    case onTarget
    /// Something that could be judged is outside the target.
    case offTarget
    /// Depth or rate could not be judged, and nothing that could be judged is wrong.
    case unseen
}
