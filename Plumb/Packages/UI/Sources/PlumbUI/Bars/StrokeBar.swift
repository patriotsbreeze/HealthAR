import PlumbContracts

/// One finished push as the bars draw it: how deep, whether it reached the line, and how far it was trusted.
public struct StrokeBar: Equatable, Sendable {
    /// Top of stroke to deepest point, in millimetres.
    public var depthMM: Double
    /// True when the push reached the target depth. Only counts when `trust` is locked.
    public var reached: Bool
    /// How far the measurement was trusted when this push was made.
    public var trust: LockState

    /// A bar from plain values.
    public init(depthMM: Double, reached: Bool, trust: LockState) {
        self.depthMM = depthMM
        self.reached = reached
        self.trust = trust
    }

    /// A bar for a measured compression, judged against the minimum target depth.
    public init(_ compression: Compression, targets: Targets = .adult) {
        self.init(depthMM: compression.depthMM,
                  reached: compression.depthMM >= targets.depthMinMM,
                  trust: compression.lock)
    }
}

/// How one finished push is drawn, chosen from whether it reached the line and how far it was trusted.
enum BarStyle: Equatable {
    /// Solid, in the mark colour: a trusted push that reached the line.
    case reached
    /// Solid, in the accent: a trusted push that fell short.
    case short
    /// A quiet outline with no judgement: depth was only an estimate.
    case outline
    /// A short tick the same length as every other: only the rhythm was trusted.
    case tick

    init(_ bar: StrokeBar) {
        switch bar.trust {
        case .locked: self = bar.reached ? .reached : .short
        case .estimating: self = .outline
        case .rateOnly, .lost: self = .tick
        }
    }

    /// The colour this style takes on a ground. Good has no colour of its own: it is the mark colour.
    func swatch(on surface: Theme.Surface) -> Theme.Swatch {
        switch self {
        case .reached, .tick: surface.mark
        case .short: Theme.Palette.accent
        case .outline: surface.quiet
        }
    }
}
