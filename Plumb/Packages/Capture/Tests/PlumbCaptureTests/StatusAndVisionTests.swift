import ARKit
import CoreGraphics
import Foundation
import Testing
import Vision
@testable import PlumbCapture

struct StatusAndVisionTests {
    @Test func visionPointsAreFlippedToTopLeftPixels() {
        // Vision measures y up from the bottom: a point 10% up from the bottom is near the image's last row.
        let size = CGSize(width: 1920, height: 1440)
        let pixel = BodyJoints.pixel(of: NormalizedPoint(x: 0.25, y: 0.1), imageSize: size)
        #expect(abs(pixel.x - 480) < 1e-9)
        #expect(abs(pixel.y - 1296) < 1e-9)
    }

    @Test func trackingStatesBecomePlainWords() {
        #expect(StatusWords.tracking(.normal) == "normal")
        #expect(StatusWords.tracking(.notAvailable) == "unavailable")
        #expect(StatusWords.tracking(.limited(.initializing)) == "starting")
        #expect(StatusWords.tracking(.limited(.excessiveMotion)) == "moving")
        #expect(StatusWords.tracking(.limited(.insufficientFeatures)) == "featureless")
        #expect(StatusWords.tracking(.limited(.relocalizing)) == "relocalizing")
    }

    @Test func thermalStatesBecomePlainWords() {
        #expect(StatusWords.thermal(.nominal) == "nominal")
        #expect(StatusWords.thermal(.critical) == "critical")
    }
}
