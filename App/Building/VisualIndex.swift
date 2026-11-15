import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// On-device photo matching, so "Where am I?" answers at once. Each survey tile is four views in a 2×2
/// grid; each view gets a Vision feature print, and a photo's print is compared with all of them.
/// About 5 ms a photo once built. Building takes a few seconds, so it starts when the section shows.
actor VisualIndex {
    /// Pano positions in `LocatorData.panos` order, each with the prints of its four views.
    private var prints: [(pano: Int, print: VNFeaturePrintObservation)]?

    var isReady: Bool { prints != nil }

    /// Safe to call often: it builds once. `extra` adds full-size views of a spot, the drone pack's
    /// look along the walk, each as three squares: a phone photo matches them far more often than the
    /// small survey quadrants alone (20 of 66 spots first, against 8, on frames from the drone video).
    func prepare(_ locator: LocatorData, tile: @Sendable (String) -> Data?, extra: @Sendable (String) -> Data? = { _ in nil }) async {
        if prints != nil { return }
        var built: [(Int, VNFeaturePrintObservation)] = []
        for (index, pano) in locator.panos.enumerated() {
            if let data = tile(pano.tile), let image = Self.image(data) {
                for view in Self.quadrants(image) {
                    if let print = Self.featurePrint(view) { built.append((index, print)) }
                }
            }
            if let data = extra(pano.id), let image = Self.image(data) {
                for view in Self.squares(image) {
                    if let print = Self.featurePrint(view) { built.append((index, print)) }
                }
            }
        }
        if prints == nil { prints = built.isEmpty ? nil : built }
    }

    /// Panos best first, by the closest of each one's views. Empty when the index isn't built or the
    /// photo can't be read.
    func rank(photo jpeg: Data, keep: Int) -> [Int] {
        guard let prints, let image = Self.image(jpeg), let query = Self.featurePrint(Self.centreSquare(image)) else { return [] }
        var closest: [Int: Float] = [:]
        for entry in prints {
            var distance: Float = 0
            guard (try? query.computeDistance(&distance, to: entry.print)) != nil else { continue }
            closest[entry.pano] = min(closest[entry.pano] ?? .infinity, distance)
        }
        return closest.sorted { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(keep).map(\.key)
    }

    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Top left, top right, bottom left, bottom right.
    static func quadrants(_ image: CGImage) -> [CGImage] {
        let width = image.width / 2
        let height = image.height / 2
        guard width > 0, height > 0 else { return [] }
        return [(0, 0), (width, 0), (0, height), (width, height)].compactMap {
            image.cropping(to: CGRect(x: $0.0, y: $0.1, width: width, height: height))
        }
    }

    /// Three squares across the long side: the start, the middle and the end.
    static func squares(_ image: CGImage) -> [CGImage] {
        let side = min(image.width, image.height)
        guard side > 0 else { return [] }
        let slack = max(image.width, image.height) - side
        let offsets = slack == 0 ? [0] : [0, slack / 2, slack]
        return offsets.compactMap { offset in
            let rect = image.width >= image.height
                ? CGRect(x: offset, y: 0, width: side, height: side)
                : CGRect(x: 0, y: offset, width: side, height: side)
            return image.cropping(to: rect)
        }
    }

    /// The views are square, so the photo is compared by its middle square.
    static func centreSquare(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        return image.cropping(to: rect) ?? image
    }

    static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        #if targetEnvironment(simulator)
        // The Simulator has no Neural Engine or Metal path for this model; the phone uses them.
        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }) {
            request.setComputeDevice(cpu, for: .main)
        }
        #endif
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        return request.results?.first
    }
}
