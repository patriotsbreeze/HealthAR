import PlumbContracts

extension CuePolicy {
    /// What to say and what to display after one look at the measurements.
    public struct Decision: Sendable, Equatable {
        /// A cue to say out loud right now. Nil on almost every look.
        public var speak: Cue?
        /// What the single command slot on screen should display right now. Nil when nothing is wrong.
        public var show: Cue?

        /// Makes a decision. With no arguments it says nothing and shows nothing.
        public init(speak: Cue? = nil, show: Cue? = nil) {
            self.speak = speak
            self.show = show
        }
    }
}
