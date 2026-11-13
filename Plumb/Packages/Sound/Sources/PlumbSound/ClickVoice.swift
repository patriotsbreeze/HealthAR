/// One sine component of a click.
public struct ClickPartial: Sendable, Equatable {
    /// Pitch in hertz.
    public var hertz: Double
    /// Loudness relative to the other partials of the same voice. 0 leaves this one out.
    public var level: Double

    /// Makes a partial at `hertz` with relative loudness `level`.
    public init(hertz: Double, level: Double) {
        self.hertz = hertz
        self.level = level
    }

    /// A partial that makes no sound, for a voice that uses fewer than three.
    public static let silent = ClickPartial(hertz: 0, level: 0)
}

/// The recipe for one click: up to three sine partials struck together and left to die away.
public struct ClickVoice: Sendable, Equatable {
    /// The lowest partial; it sets the pitch the ear hears.
    public var first: ClickPartial
    /// The second partial.
    public var second: ClickPartial
    /// The third partial. Use `.silent` for a thinner sound.
    public var third: ClickPartial
    /// Seconds for the ring to fall to about a third (1/e) of its struck level.
    public var decaySeconds: Double

    /// Makes a voice from its partials and how fast it dies away.
    public init(first: ClickPartial, second: ClickPartial, third: ClickPartial = .silent,
                decaySeconds: Double) {
        self.first = first
        self.second = second
        self.third = third
        self.decaySeconds = decaySeconds
    }
}
