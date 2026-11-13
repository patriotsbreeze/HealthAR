import CoreGraphics

extension Theme {
    /// The few numbers only the chest check's screen needs, kept beside it so the shared metrics stay as they are.
    struct ChestMetrics: Equatable, Sendable {
        /// Height of the headline slot: two lines of the command face, because "START PUSHING" is wider than
        /// the panel and the command face never shrinks to fit. Fixed, so the line below never moves.
        var headlineHeight: CGFloat = 152
        /// Millimetres of chest height that span the trace from bottom to top. Fixed, never fitted to the line,
        /// so a still chest is drawn flat instead of having its noise blown up to fill the space.
        var fullScaleMM: Double = 20
        /// Thickness of the trace line.
        var traceWidth: CGFloat = 2
        /// Strength of the threshold band against the ground. Faint: it is a guide to the line, not content.
        var bandOpacity: Double = 0.22
        /// Height kept for the one line of context, so the trace does not move when it comes or goes.
        var contextHeight: CGFloat = 24
    }

    /// The chest screen's numbers.
    static let chest = ChestMetrics()
}
