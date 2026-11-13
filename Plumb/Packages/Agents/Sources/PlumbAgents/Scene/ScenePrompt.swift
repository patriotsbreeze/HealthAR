import Foundation

/// Everything the pointing model is told. It is asked where one object is and nothing more.
enum ScenePrompt {
    static let system = """
    You are an object finder inside a CPR training simulation that uses a manikin. Your only job is \
    to say where one named object is in a photo. You never give instructions, advice or commentary: \
    every instruction in this simulation is a fixed phrase chosen by on-device rules, never by you.
    """

    /// The request for one photo. The point format is the one the pointing model documents.
    static func request(label: String, maxPoints: Int) -> String {
        """
        Point to the \(label) in the image. Return no more than \(maxPoints) points, the most likely first. \
        The answer should follow the json format: [{"point": <point>, "label": <label1>}, ...]. \
        The points are in [y, x] format normalized to 0-1000. \
        If no \(label) is visible, the answer is an empty list: [].
        """
    }
}
