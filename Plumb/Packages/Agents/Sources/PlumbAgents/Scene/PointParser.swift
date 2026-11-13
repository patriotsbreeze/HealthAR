import Foundation

/// Reads the pointing model's answer. The model is not trusted to keep to the format, so anything
/// that is not a usable point is dropped rather than repaired.
enum PointParser {
    /// The model's scale: coordinates run from 0 to this value.
    private static let scale = 1000.0

    /// The usable points in the answer, at most `limit`, in the model's order.
    ///
    /// Returns nil when the answer is not a list at all, and an empty array when it is a list with
    /// nothing usable in it. The documented form is `[{"point": [y, x], "label": "…"}]`.
    static func points(in answer: Data, limit: Int) -> [ScenePoint]? {
        let body = FencedJSON.unwrap(String(decoding: answer, as: UTF8.self))
        guard let items = list(in: body) else { return nil }
        let points = items.compactMap { item -> ScenePoint? in
            guard let pair = item["point"]?.array, pair.count == 2,
                  let y = pair[0].number, let x = pair[1].number,
                  (0...scale).contains(y), (0...scale).contains(x) else { return nil }
            return ScenePoint(x: x / scale, y: y / scale, label: Scrubber.label(item["label"]?.string ?? ""))
        }
        return Array(points.prefix(limit))
    }

    /// The JSON list in the text. Text that is JSON but not a list is the wrong form. Text that is
    /// not JSON at all may be a list with words around it, so the outermost brackets are tried.
    private static func list(in body: String) -> [JSONValue]? {
        if let whole = try? JSONValue(parsing: Data(body.utf8)) {
            return whole.array
        }
        guard let open = body.firstIndex(of: "["), let close = body.lastIndex(of: "]"), open < close else {
            return nil
        }
        return (try? JSONValue(parsing: Data(body[open...close].utf8)))?.array
    }
}
