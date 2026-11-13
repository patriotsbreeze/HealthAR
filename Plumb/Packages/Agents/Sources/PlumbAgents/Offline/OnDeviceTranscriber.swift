import AVFoundation
import Speech

/// Push-to-talk speech to text that never uses the network.
///
/// It prefers the newer recognizer (iOS 26), whose speech model `prepare()` installs, and otherwise
/// uses the older recognizer held to on-device recognition. It owns its own audio engine and its own
/// tap on the microphone, so it must never run while `MicCapture` is running: the app uses one or the
/// other for a press, never both. Like `MicCapture`, it does not ask for microphone permission and does
/// not set the audio session category; the app does both before calling `begin()`.
@MainActor
public final class OnDeviceTranscriber: SpeechTranscribing {
    /// Why listening could not start.
    public enum Failure: Error, Equatable {
        /// `prepare()` has not found a way to listen on this phone. The reason is plain words.
        case notReady(reason: String)
        /// The last question is still being turned into text.
        case busy
        /// There is no microphone input, or the app has no permission to use it.
        case noInput
        /// The microphone's format could not be converted.
        case unsupportedFormat
    }

    /// How questions will be heard, as `prepare()` last found.
    public private(set) var readiness = TranscriberReadiness.unavailable(reason: "Speech recognition has not been set up yet.")

    private enum Route {
        /// The newer recognizer, with the locale it supports and the audio format it takes.
        case analyzer(locale: Locale, format: AVAudioFormat)
        /// The older recognizer, already checked for on-device recognition and permission.
        case recognizer(SFSpeechRecognizer)
    }

    private let locale: Locale
    private let finishLimit: Duration
    private let engine = AVAudioEngine()
    private var route: Route?
    private var preparing: Task<Void, Never>?
    private var sink: (any SpeechSink)?
    private var finishing = false

    /// - Parameters:
    ///   - locale: the language questions are asked in.
    ///   - finishLimit: how long to wait for the last words after the button comes up. What was heard
    ///     by then is used.
    public init(locale: Locale = .current, finishLimit: Duration = .seconds(3)) {
        self.locale = locale
        self.finishLimit = finishLimit
    }

    /// Finds a recognizer that works on this phone without the network, and gets it ready.
    ///
    /// The newer recognizer's speech model is downloaded here when it is missing, which needs the
    /// network once; call this while online, at launch, so later questions work offline. When the older
    /// recognizer is used, this asks for speech recognition permission the first time, so the app's
    /// Info.plist must carry `NSSpeechRecognitionUsageDescription`.
    @discardableResult
    public func prepare() async -> TranscriberReadiness {
        if case .ready(.speechAnalyzer) = readiness { return readiness }
        if let preparing {
            await preparing.value
            return readiness
        }
        let attempt = Task { await self.findRoute() }
        preparing = attempt
        await attempt.value
        preparing = nil
        return readiness
    }

    /// Starts listening. Does nothing when already listening.
    public func begin() throws {
        guard sink == nil else { return }
        guard !finishing else { throw Failure.busy }
        guard let route else {
            if case .unavailable(let reason) = readiness { throw Failure.notReady(reason: reason) }
            throw Failure.notReady(reason: "Speech recognition has not been set up yet.")
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        let sink = try Self.makeSink(route, microphoneFormat: format)
        // About a tenth of a second per buffer. The system may hand over longer ones.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format,
                         block: Self.tap(feeding: sink))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink.cancel()
            throw error
        }
        self.sink = sink
    }

    /// Stops listening and returns what was said. Nil when nothing was heard or nothing was listening.
    public func finish() async -> String? {
        guard let sink else { return nil }
        self.sink = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        finishing = true
        defer { finishing = false }
        return await sink.close(within: finishLimit)
    }

    // MARK: - Private

    /// Tries the newer recognizer, then the older one. An older recognizer already in use is kept
    /// when the newer one is still out of reach.
    private func findRoute() async {
        var reasons: [String] = []
        if #available(iOS 26.0, macOS 26.0, *) {
            switch await Self.prepareAnalyzer(locale: locale) {
            case .success(let (supported, format)):
                route = .analyzer(locale: supported, format: format)
                readiness = .ready(.speechAnalyzer)
                return
            case .failure(let problem):
                reasons.append(problem.reason)
            }
        }
        if readiness.isReady { return }
        switch await Self.prepareRecognizer(locale: locale) {
        case .success(let recognizer):
            route = .recognizer(recognizer)
            readiness = .ready(.speechRecognizer)
        case .failure(let problem):
            reasons.append(problem.reason)
            readiness = .unavailable(reason: reasons.joined(separator: " "))
        }
    }

    private static func makeSink(_ route: Route, microphoneFormat: AVAudioFormat) throws -> any SpeechSink {
        switch route {
        case .analyzer(let locale, let format):
            guard #available(iOS 26.0, macOS 26.0, *),
                  let sink = AnalyzerSink(locale: locale, analyzerFormat: format, microphoneFormat: microphoneFormat) else {
                throw Failure.unsupportedFormat
            }
            return sink
        case .recognizer(let recognizer):
            return RecognizerSink(recognizer: recognizer)
        }
    }

    /// The tap block, made outside the main actor: the engine calls it on the audio thread.
    private nonisolated static func tap(feeding sink: any SpeechSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.feed(buffer) }
    }

    /// Why one recognizer cannot be used, in plain words.
    struct Problem: Error {
        var reason: String
    }

    /// The newer recognizer's locale and audio format, with its speech model installed. Not private,
    /// so a test can run it for real on a Mac.
    @available(iOS 26.0, macOS 26.0, *)
    nonisolated static func prepareAnalyzer(locale: Locale) async -> Result<(Locale, AVAudioFormat), Problem> {
        guard SpeechTranscriber.isAvailable else {
            return .failure(Problem(reason: "This phone cannot run the newer speech recognizer."))
        }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .failure(Problem(reason: "The newer speech recognizer does not support this language."))
        }
        let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if await AssetInventory.status(forModules: [module]) != .installed {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                return .failure(Problem(reason: "The speech model could not be downloaded. Connect to the internet once to fetch it."))
            }
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            return .failure(Problem(reason: "The speech model is not installed yet."))
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            return .failure(Problem(reason: "The newer speech recognizer has no audio format it can take."))
        }
        return .success((supported, format))
    }

    /// The older recognizer, when it can work on the phone and is allowed to.
    private nonisolated static func prepareRecognizer(locale: Locale) async -> Result<SFSpeechRecognizer, Problem> {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .failure(Problem(reason: "Speech recognition does not support this language."))
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .failure(Problem(reason: "This phone cannot recognise speech without the internet."))
        }
        guard await authorization() == .authorized else {
            return .failure(Problem(reason: "Speech recognition is not allowed. Turn it on in Settings to ask questions."))
        }
        return .success(recognizer)
    }

    /// Speech recognition permission, asking for it the first time.
    private nonisolated static func authorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}
