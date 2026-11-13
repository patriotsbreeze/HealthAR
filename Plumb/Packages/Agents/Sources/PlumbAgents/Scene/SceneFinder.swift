import Foundation

/// Finds an object by asking a model where it is and then testing each answer against the depth
/// sensor. The model only proposes. Nothing it says is used until `SceneJudge` agrees.
public struct SceneFinder: Sendable {
    private let client: any JSONGenerating
    private let config: AgentsConfig

    /// - Parameter client: where the pointing requests go. `GeminiClient` in the app, a fake in tests.
    public init(client: any JSONGenerating, config: AgentsConfig = AgentsConfig()) {
        self.client = client
        self.config = config
    }

    /// Asks the pointing model where the labelled object is in a JPEG. Returns at most
    /// `sceneMaxPoints` points relative to that image, or none when the model cannot be reached,
    /// answers in the wrong form, or sees no such object.
    public func propose(jpeg: Data, label: String) async -> [ScenePoint] {
        await ask(jpeg: jpeg, label: subject(label)).points
    }

    /// Looks for the object and returns every guess with its verdict.
    ///
    /// One frame is sent to the model and each point it proposes is probed and judged, nearest
    /// first. If none is accepted, one more frame is taken, zoomed in on the guess that came closest
    /// to passing, and judged the same way. Then it stops.
    ///
    /// - Parameters:
    ///   - label: what to look for. Nil uses `sceneLabel`.
    ///   - capture: takes a fresh frame and returns the given region of it as a JPEG, with a
    ///     function that probes points given relative to the whole frame. Nil when no frame is available.
    public func find(label: String? = nil,
                     capture: @Sendable (SceneRegion) async -> SceneCapture?) async -> SceneResult {
        var result = SceneResult(label: subject(label))
        var region = SceneRegion.full
        for round in 1...2 {
            guard let frame = await capture(region) else {
                result.failure = "No camera frame was available."
                break
            }
            result.looks = round
            let answer = await ask(jpeg: frame.jpeg, label: result.label)
            result.failure = answer.failure

            var judged: [SceneProposal] = []
            for point in answer.points.map(region.inFullFrame) {
                let verdict = await frame.probe(point).map { SceneJudge.judge($0, config: config) }
                    ?? SceneVerdict(finding: .unmeasured, reason: "No depth reading there.")
                judged.append(SceneProposal(point: point, round: round, verdict: verdict))
            }
            // Nearest first: when two candidates pass, the closer one is the one to walk to.
            judged.sort { ($0.verdict.distanceM ?? .infinity) < ($1.verdict.distanceM ?? .infinity) }
            result.proposals += judged

            if let hit = judged.first(where: \.verdict.accepted) {
                result.accepted = hit
                break
            }
            // The guess that got furthest through the checks is the best place to look closer.
            guard let closest = judged.max(by: { $0.verdict.finding < $1.verdict.finding }) else { break }
            region = SceneRegion.zoomed(around: closest.point, factor: config.sceneZoomFactor)
        }
        return result
    }

    // MARK: - Private

    /// The label as it goes into a prompt and the log: cut down to plain characters, and never empty.
    private func subject(_ label: String?) -> String {
        let cleaned = Scrubber.label(label ?? "")
        return cleaned.isEmpty ? config.sceneLabel : cleaned
    }

    /// One answer from the pointing model, trying the fallback model when the first cannot be used.
    private func ask(jpeg: Data, label: String) async -> (points: [ScenePoint], failure: String?) {
        var failure: String?
        var models = [config.pointingModel]
        if config.pointingFallbackModel != config.pointingModel {
            models.append(config.pointingFallbackModel)
        }
        for model in models {
            do {
                let answer = try await client.generateJSON(
                    model: model, system: ScenePrompt.system,
                    parts: [.jpeg(jpeg), .text(ScenePrompt.request(label: label, maxPoints: config.sceneMaxPoints))],
                    schema: nil, thinking: config.pointingThinkingLevel, timeout: config.pointingTimeout)
                if let points = PointParser.points(in: answer, limit: config.sceneMaxPoints) {
                    return (points, nil)
                }
                failure = "The object finder's answer was not in the agreed form."
            } catch let error as GeminiError {
                failure = "The object finder could not be reached. \(error.description)"
            } catch {
                // An unknown error could say anything, so it is not repeated.
                failure = "The object finder could not be reached."
            }
        }
        return ([], failure)
    }
}
