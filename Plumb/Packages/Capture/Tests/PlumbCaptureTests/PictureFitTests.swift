import CoreGraphics
import Testing
@testable import PlumbCapture

struct PictureFitTests {
    /// A 4:3 picture in a wide view: bars left and right.
    let wide = PictureFit(imageSize: CGSize(width: 1920, height: 1440), viewSize: CGSize(width: 1000, height: 600))

    @Test func picturesAreFittedWholeAndCentred() {
        let frame = wide.pictureFrame
        #expect(frame.height == 600 && frame.width == 800)
        #expect(frame.minX == 100 && frame.minY == 0)
        let tall = PictureFit(imageSize: CGSize(width: 4, height: 3), viewSize: CGSize(width: 400, height: 900))
        #expect(tall.pictureFrame == CGRect(x: 0, y: 300, width: 400, height: 300))
    }

    @Test func tapsMapToNormalisedImagePoints() {
        #expect(wide.imagePoint(fromViewPoint: CGPoint(x: 500, y: 300)) == CGPoint(x: 0.5, y: 0.5))
        #expect(wide.imagePoint(fromViewPoint: CGPoint(x: 100, y: 0)) == CGPoint(x: 0, y: 0))
        #expect(wide.imagePoint(fromViewPoint: CGPoint(x: 900, y: 600)) == CGPoint(x: 1, y: 1))
        #expect(wide.imagePoint(fromViewPoint: CGPoint(x: 300, y: 150)) == CGPoint(x: 0.25, y: 0.25))
    }

    @Test func tapsOnTheBarsAreIgnored() {
        #expect(wide.imagePoint(fromViewPoint: CGPoint(x: 50, y: 300)) == nil)
        #expect(wide.imagePoint(fromViewPoint: CGPoint(x: 950, y: 300)) == nil)
    }

    @Test func aHalfTurnFlipsBothWays() {
        let turned = PictureFit(imageSize: wide.imageSize, viewSize: wide.viewSize, halfTurn: true)
        #expect(turned.imagePoint(fromViewPoint: CGPoint(x: 100, y: 0)) == CGPoint(x: 1, y: 1))
        #expect(turned.imagePoint(fromViewPoint: CGPoint(x: 300, y: 150)) == CGPoint(x: 0.75, y: 0.75))
        #expect(turned.viewPoint(fromImagePoint: CGPoint(x: 0.75, y: 0.75)) == CGPoint(x: 300, y: 150))
    }

    @Test func viewAndImagePointsRoundTrip() {
        for fit in [wide, PictureFit(imageSize: wide.imageSize, viewSize: wide.viewSize, halfTurn: true)] {
            let image = CGPoint(x: 0.3, y: 0.8)
            let back = fit.imagePoint(fromViewPoint: fit.viewPoint(fromImagePoint: image))
            #expect(back.map { abs($0.x - 0.3) < 1e-12 && abs($0.y - 0.8) < 1e-12 } == true)
        }
    }

    @Test func imageRectsBecomeViewRects() {
        let rect = wide.viewRect(fromImageRect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        #expect(rect == CGRect(x: 300, y: 300, width: 400, height: 150))
        let turned = PictureFit(imageSize: wide.imageSize, viewSize: wide.viewSize, halfTurn: true)
        #expect(turned.viewRect(fromImageRect: CGRect(x: 0, y: 0, width: 0.25, height: 0.5))
            == CGRect(x: 700, y: 300, width: 200, height: 300))
    }

    @Test func emptySizesFitNothing() {
        let empty = PictureFit(imageSize: .zero, viewSize: CGSize(width: 100, height: 100))
        #expect(empty.pictureFrame == .zero)
        #expect(empty.imagePoint(fromViewPoint: .zero) == nil)
    }
}
