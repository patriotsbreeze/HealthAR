import CoreGraphics
import Testing
import UIKit
@testable import PlumbCapture

/// The flat overlay that points the way to an AED out of sight.
@MainActor
struct AEDPointerViewTests {
    @Test func thePointerSitsAtTheEdgeWithItsWordsInside() {
        let pointer = AEDPointerView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(pointer.isHidden && !pointer.isUserInteractionEnabled)
        #expect(pointer.edge == CGRect(x: 22, y: 22, width: 756, height: 556))
        let placement = EdgePointer.Placement(position: CGPoint(x: 778, y: 300), angle: 0)
        pointer.show(placement, text: "AED 4.2 m")
        #expect(!pointer.isHidden)
        #expect(pointer.chevron.center == placement.position)
        #expect(pointer.words.text == "AED 4.2 m")
        #expect(pointer.bounds.contains(pointer.words.frame))
        // Beside the chevron on the inside, clear of it.
        #expect(pointer.words.frame.maxX <= placement.position.x - AEDPointerView.chevronSidePt / 2)
        #expect(abs(pointer.words.frame.midY - placement.position.y) < 1e-9)
        pointer.hide()
        #expect(pointer.isHidden)
    }

    @Test func theChevronTurnsToPointTheWay() {
        let pointer = AEDPointerView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        pointer.show(EdgePointer.Placement(position: CGPoint(x: 400, y: 578), angle: .pi / 2), text: "AED 12 m")
        let turned = pointer.chevron.transform
        #expect(abs(atan2(turned.b, turned.a) - .pi / 2) < 1e-9)
        // Pointing down: the words sit above the chevron.
        #expect(pointer.words.frame.maxY <= 578 - AEDPointerView.chevronSidePt / 2)
    }
}
