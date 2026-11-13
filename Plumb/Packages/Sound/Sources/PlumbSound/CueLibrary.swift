import PlumbContracts

/// Which cues are spoken words and which had to fall back to tones, and why.
public struct CueRenderReport: Sendable, Equatable {
    /// How one cue ended up.
    public enum Outcome: Sendable, Equatable {
        /// The cue is spoken words.
        case speech
        /// The cue is its tone pattern. `reason` is one plain sentence saying why.
        case fallbackTone(reason: String)
    }

    private var outcomes: [Cue: Outcome] = [:]
    private let unrendered: Outcome

    /// A report in which every cue is still `outcome`.
    init(everyCue outcome: Outcome) {
        unrendered = outcome
    }

    /// How a cue ended up.
    public func outcome(for cue: Cue) -> Outcome {
        outcomes[cue] ?? unrendered
    }

    /// The cues that are tones instead of speech, in the order the contract lists them.
    public var fallbackCues: [Cue] {
        Cue.allCases.filter { outcome(for: $0) != .speech }
    }

    /// True when every cue is spoken words.
    public var allSpoken: Bool {
        fallbackCues.isEmpty
    }

    mutating func record(_ outcome: Outcome, for cue: Cue) {
        outcomes[cue] = outcome
    }
}

/// The five cues as ready-to-play audio at the engine's sample rate, with a note of how each was made.
public struct CueLibrary: Sendable, Equatable {
    /// Which cues are speech and which are tones.
    public private(set) var report: CueRenderReport

    private var spoken: [Cue: MonoClip] = [:]
    private let tones: FallbackTones

    /// A library of tone patterns only. It is what plays until speech has been rendered.
    public init(config: BeatEngine.Config = .init()) {
        tones = FallbackTones(config: config)
        report = CueRenderReport(everyCue: .fallbackTone(reason: "Speech has not been rendered yet."))
    }

    /// Renders every cue's phrase once with `speaker`. A cue whose phrase fails keeps its tones,
    /// and the report says why.
    public static func rendered(by speaker: any CueSpeaking,
                                config: BeatEngine.Config = .init()) async -> CueLibrary {
        var library = CueLibrary(config: config)
        var gaveUp: String?
        for cue in Cue.allCases {
            if let gaveUp {
                library.report.record(.fallbackTone(reason: gaveUp), for: cue)
                continue
            }
            do {
                let raw = try await speaker.render(CuePhrasebook.spokenText(for: cue))
                library.spoken[cue] = try raw.readied(for: config)
                library.report.record(.speech, for: cue)
            } catch {
                library.report.record(.fallbackTone(reason: String(describing: error)), for: cue)
                // A service that has stopped answering would make each remaining phrase wait out
                // its whole time limit, so the rest go straight to tones.
                if let failure = error as? CueSpeechError, case .timedOut = failure {
                    gaveUp = "Not tried: the speech service had already stopped answering."
                }
            }
        }
        return library
    }

    /// The audio for a cue: its spoken phrase, or its tone pattern if speech was not available.
    public func clip(for cue: Cue) -> MonoClip {
        spoken[cue] ?? tones.clip(for: cue)
    }
}

private extension MonoClip {
    /// Speech as the engine wants it: no dead air at either end, at the engine's rate, at cue level.
    func readied(for config: BeatEngine.Config) throws -> MonoClip {
        guard peak > 0 else { throw CueSpeechError.noAudio }
        let trimmed = trimmingQuietEnds(floor: config.cueSilenceFloor, padSeconds: config.cueTrimPadSeconds)
        guard let resampled = trimmed.resampled(to: config.sampleRate, config: config) else {
            throw CueSpeechError.unreadableAudio
        }
        return resampled.scaled(toPeak: config.cuePeak)
    }
}
