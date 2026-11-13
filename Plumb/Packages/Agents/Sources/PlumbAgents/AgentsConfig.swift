import Foundation

/// Every tunable and model name the agents use, in one place.
///
/// The defaults suit a phone propped about a metre from a manikin. To change one, copy the struct:
/// `var config = AgentsConfig(); config.textModel = "…"`.
public struct AgentsConfig: Sendable, Equatable {

    // MARK: Models

    /// Fast text model that writes the handoff sentences.
    public var textModel = "gemini-3.8-flash"
    /// Model asked to point at an object in a photo.
    public var pointingModel = "gemini-robotics-er-2-preview"
    /// Used for pointing when the pointing model cannot be reached or answers in the wrong form.
    public var pointingFallbackModel = "gemini-3.8-flash"
    /// Speech-to-speech model behind the push-to-talk voice.
    public var liveModel = "gemini-3.8-live"
    /// Prebuilt voice name for the live model. Nil leaves the service's own default voice.
    public var voiceName: String?

    // MARK: Plain HTTPS calls

    /// Which request and response shape the HTTPS calls use.
    public var restDialect = GenerateDialect.interactions
    /// Sent as the `Api-Revision` header on the interactions endpoint so the response shape cannot
    /// change underneath the parser. Nil leaves the header out.
    public var apiRevision: String? = "2026-05-20"
    /// Wait before the single retry after a transport failure or a 5xx.
    public var retryPause = Duration.milliseconds(250)
    /// Longest piece of a server's answer that may appear in an error description.
    public var errorDetailLimit = 160

    // MARK: Conductor

    /// Tool calls allowed to run at once. Extra calls are refused, not queued.
    public var maxConcurrentToolCalls = 2
    /// How long the built-in measurement tool may take before it is cancelled.
    public var toolDeadline = Duration.seconds(1)

    // MARK: Scribe

    /// Whole budget for one scribe request, including its retry.
    public var scribeTimeout = Duration.seconds(12)
    /// Thinking level for the scribe. `low` keeps the handoff quick. Nil leaves the model's default.
    public var scribeThinkingLevel: String? = "low"
    /// Most sentences the scribe may contribute.
    public var scribeMaxSentences = 3
    /// Most words allowed in one scribe sentence.
    public var scribeMaxWords = 30
    /// Above this many usable log entries the scribe is given a thinned list instead of all of them.
    public var scribeFullLogLimit = 300
    /// In a thinned list, every nth compression is kept.
    public var scribeCompressionStride = 10

    // MARK: Scene finder

    /// What the scene finder looks for when no label is given.
    public var sceneLabel = "AED"
    /// Most points taken from one answer of the pointing model.
    public var sceneMaxPoints = 3
    /// Whole budget for one pointing request, including its retry.
    public var pointingTimeout = Duration.seconds(10)
    /// Thinking level for pointing. `low` is accepted by both pointing models. Nil leaves the default.
    public var pointingThinkingLevel: String? = "low"
    /// How far the second look zooms in around the best rejected point.
    public var sceneZoomFactor = 2.0
    /// Nearest distance at which the depth sensor is trusted, in metres.
    public var sceneMinDistanceM = 0.3
    /// Farthest distance at which the depth sensor is trusted, in metres.
    public var sceneMaxDistanceM = 5.0
    /// Shortest plausible side of a portable defibrillator case, in metres.
    public var sceneMinSideM = 0.15
    /// Longest plausible side of a portable defibrillator case, in metres.
    public var sceneMaxSideM = 0.6
    /// How far an object must stand out from the surface behind it, in metres. This is what
    /// rejects a sign, a poster or a picture on a screen.
    public var sceneMinReliefM = 0.04
    /// How many times the sensor's own noise an object must stand out by. Keeps a noisy reading of
    /// a bare wall from passing as relief.
    public var sceneReliefNoiseMultiple = 3.0
    /// Real-world width the depth grid should cover at the object's distance, in metres. Wide
    /// enough to see the surface around the largest plausible case.
    public var sceneProbeSpanM = 1.0
    /// Share of the outer edge of the depth grid treated as the surface around the object, 0...0.5.
    public var sceneBorderFraction = 0.15
    /// Share of the depth grid that must hold a reading before anything is judged, 0...1.
    public var sceneMinValidFraction = 0.5

    // MARK: Voice

    /// How long the live service may take to accept the connection and its setup.
    public var voiceSetupTimeout = Duration.seconds(8)
    /// Length of each microphone chunk in milliseconds.
    public var micChunkMs = 30
    /// Largest single message accepted from the live service, in bytes.
    public var socketMaxMessageBytes = 4 * 1024 * 1024

    /// Creates a configuration holding the documented defaults.
    public init() {}
}
