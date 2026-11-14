import AVFoundation
import Foundation
import RescueLive

/// Speaks the building lines in the app's own voice: the same prebuilt Gemini voice the live AI and the
/// phrase clips use (`GeminiVoice` in Info.plist), rendered by Gemini's text-to-speech. Fetched ahead
/// once the building is confirmed, so a tap plays at once. Any failure falls back to the on-device
/// read-aloud the rest of the app uses, so a line is never lost.
@MainActor
final class BuildingVoice {
    static let shared = BuildingVoice()
    nonisolated static let model = "gemini-3.8-flash-tts"
    nonisolated static let timeout: TimeInterval = 8

    private var cache: [String: Data] = [:]
    private var pending: [String: Task<Data?, Never>] = [:]
    private var player: AVAudioPlayer?
    private let http: HTTPClient

    init(http: @escaping HTTPClient = liveHTTPClient) {
        self.http = http
    }

    /// Renders ahead, so the tap that follows needn't wait.
    func prefetch(_ text: String) {
        _ = audio(for: text)
    }

    func speak(_ text: String, fallback: @escaping @MainActor () -> Void) {
        let task = audio(for: text)
        Task { @MainActor in
            guard let data = await task.value, let player = try? AVAudioPlayer(data: data) else {
                fallback()
                return
            }
            self.player?.stop()
            self.player = player
            player.play()
        }
    }

    private func audio(for text: String) -> Task<Data?, Never> {
        if let cached = cache[text] { return Task { cached } }
        if let running = pending[text] { return running }
        let request = Self.request(text: text)
        let http = http
        let task = Task { @MainActor [weak self] () -> Data? in
            defer { self?.pending[text] = nil }
            guard let request else { return nil }
            let data = await PhotoMatcher.withDeadline(Self.timeout) { () -> Data? in
                guard let (body, response) = try? await http(request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return Self.audio(from: body)
            }
            if let data { self?.cache[text] = data }
            return data
        }
        pending[text] = task
        return task
    }

    nonisolated static func request(text: String, bundle: Bundle = .main) -> URLRequest? {
        guard let raw = bundle.object(forInfoDictionaryKey: "GeminiAPIKey") as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix("$("),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        else { return nil }
        let voice = (bundle.object(forInfoDictionaryKey: "GeminiVoice") as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "Kore"
        let body: [String: Any] = [
            "contents": [["parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]],
            ],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = payload
        return request
    }

    /// The first inline audio part, as something AVAudioPlayer plays: WAV as given, raw 16-bit PCM wrapped.
    nonisolated static func audio(from body: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let parts = (((root["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"]) as? [[String: Any]],
              let inline = parts.compactMap({ $0["inlineData"] as? [String: Any] }).first,
              let base64 = inline["data"] as? String, let data = Data(base64Encoded: base64), !data.isEmpty
        else { return nil }
        let mime = (inline["mimeType"] as? String ?? "").lowercased()
        if mime.contains("wav") { return data }
        let rate = mime.components(separatedBy: "rate=").dropFirst().first.flatMap { Int($0.prefix { $0.isNumber }) } ?? 24_000
        return wav(pcm: data, sampleRate: rate)
    }

    /// A RIFF header for mono 16-bit little-endian PCM.
    nonisolated static func wav(pcm: Data, sampleRate: Int) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var data = Data("RIFF".utf8)
        data += le(UInt32(36 + pcm.count))
        data += Data("WAVEfmt ".utf8)
        data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))
        data += le(UInt32(sampleRate)) + le(UInt32(sampleRate * 2)) + le(UInt16(2)) + le(UInt16(16))
        data += Data("data".utf8) + le(UInt32(pcm.count)) + pcm
        return data
    }
}
