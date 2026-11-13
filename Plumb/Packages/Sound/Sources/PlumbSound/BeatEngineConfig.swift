extension BeatEngine {
    /// Every number that shapes the sound, in one place.
    /// The defaults are tuned for an iPhone speaker about a metre from the rescuer.
    public struct Config: Sendable, Equatable {

        // MARK: The graph

        /// Samples per second the beat is generated at. Default 48 000, the iPhone speaker's own
        /// rate, so the beat reaches the hardware without being resampled.
        public var sampleRate: Double = 48_000

        // MARK: The click

        /// Peak level of every click at full gain, where 1 is the most the output can carry. Default 0.8.
        public var beatLevel: Double = 0.8
        /// Length of one click in seconds. Default 0.045; outside it the beat is exact silence.
        public var clickSeconds: Double = 0.045
        /// Seconds a click takes to rise to full level. Default 0.001, fast enough to sound struck.
        public var clickAttackSeconds: Double = 0.001
        /// Seconds at the end of a click over which it is faded to exact silence. Default 0.005.
        public var clickReleaseSeconds: Double = 0.005
        /// The thin click played when the last compression fell short. Default 2500 Hz and 3750 Hz,
        /// dying away in 5 ms: high and brief, in the band a phone speaker is loudest.
        public var tick = ClickVoice(first: ClickPartial(hertz: 2500, level: 1),
                                     second: ClickPartial(hertz: 3750, level: 0.5),
                                     decaySeconds: 0.005)
        /// The full click played when the last compression reached the line. Default 520, 1040 and
        /// 1560 Hz, dying away in 18 ms. The upper two carry the low pitch on a speaker too small
        /// to move much air at 520 Hz.
        public var tock = ClickVoice(first: ClickPartial(hertz: 520, level: 1),
                                     second: ClickPartial(hertz: 1040, level: 0.6),
                                     third: ClickPartial(hertz: 1560, level: 0.3),
                                     decaySeconds: 0.018)

        // MARK: Speech over the beat

        /// Gain of the beat while speech plays, as a share of its normal gain. Default 0.5.
        public var duckedGain: Double = 0.5
        /// Seconds the beat takes to slide between full and ducked gain. Default 0.03, slow enough
        /// not to be heard as a click of its own.
        public var duckRampSeconds: Double = 0.03
        /// Seconds the beat stays ducked after speech should have ended. Default 0.12, which covers
        /// the block or two a player may wait before it starts.
        public var speechTailSeconds: Double = 0.12
        /// Peak level every cue is scaled to. Default 0.6, so a ducked beat plus a cue
        /// (0.8 x 0.5 + 0.6) never exceeds what the output can carry.
        public var cuePeak: Double = 0.6
        /// Language of the voice that speaks the cues, as a BCP 47 code. Default "en-US".
        public var cueLanguage: String = "en-US"
        /// Speaking rate from 0 (slowest) to 1 (fastest). Default 0.5, the system's normal rate.
        public var cueSpeechRate: Double = 0.5
        /// Seconds to wait for one phrase before giving up on speech. Default 10; a voice's first
        /// phrase can take a few seconds while the system loads it.
        public var cueRenderTimeoutSeconds: Double = 10
        /// Speech quieter than this share of its own peak counts as silence and is trimmed from
        /// both ends of a cue. Default 0.005.
        public var cueSilenceFloor: Double = 0.005
        /// Seconds of that quiet lead-in and tail kept, so soft consonants are not clipped. Default 0.02.
        public var cueTrimPadSeconds: Double = 0.02

        // MARK: Tones used when a cue cannot be spoken

        /// Pitch of the low fallback note in hertz. Default 880.
        public var fallbackLowHz: Double = 880
        /// Pitch of the high fallback note in hertz. Default 1320.
        public var fallbackHighHz: Double = 1320
        /// Length of a short fallback note in seconds. Default 0.09.
        public var fallbackShortSeconds: Double = 0.09
        /// Length of a long fallback note in seconds. Default 0.2.
        public var fallbackLongSeconds: Double = 0.2
        /// Silence between fallback notes in seconds. Default 0.06.
        public var fallbackGapSeconds: Double = 0.06
        /// Seconds each fallback note takes to fade in and out. Default 0.005.
        public var fallbackEdgeSeconds: Double = 0.005

        // MARK: Speech from a voice model

        /// Gain applied to model speech. Default 1: it plays at whatever level the model chose.
        public var modelGain: Double = 1
        /// Sample rates accepted for model speech. Audio at any other rate is ignored.
        /// Default 8000 to 96 000.
        public var modelSampleRateRange: ClosedRange<Double> = 8_000...96_000

        // MARK: Changing sample rate

        /// How many ripples of the interpolation curve are kept each side of a sample when speech
        /// is brought to the engine's sample rate. Default 16. More is cleaner and slower.
        public var resamplerZeroCrossings: Int = 16
        /// Share of the available frequency range kept when changing sample rate. Default 0.95;
        /// the top twentieth is given up so that nothing false is added above it.
        public var resamplerCutoff: Double = 0.95

        // MARK: The visual

        /// Furthest the sound at the speaker may be assumed to trail the sound being generated,
        /// in seconds. Default 0.25. Bounds `beatPhase` if the clock it relies on misbehaves.
        public var maxPlayheadLagSeconds: Double = 0.25

        // MARK: iOS

        /// Whether the engine sets the audio session to playback and activates it. Default true.
        /// Set to false when another part of the app owns the session.
        public var managesAudioSession: Bool = true

        /// Makes a configuration with every default.
        /// True when the app will record from the microphone while the beat plays (push-to-talk).
        /// The audio session then allows recording; output still goes to the loudspeaker.
        public var sharesMicrophone = false

        public init() {}
    }
}
