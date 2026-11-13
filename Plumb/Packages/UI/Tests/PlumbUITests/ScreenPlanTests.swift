import CoreGraphics
import Testing
@testable import PlumbUI

@Suite struct ScreenPlanTests {
    static let phone = CGSize(width: 874, height: 402)
    static let mirrored = CGSize(width: 1280, height: 720)

    @Test func onThePhoneThePictureFillsTheHeightAndThePanelTakesTheRest() {
        let plan = ScreenPlan(size: Self.phone, panelReferenceWidth: Theme.metrics.panelWidth)
        #expect(plan.unit == 1)
        #expect(plan.pictureSize == CGSize(width: 536, height: 402))
        #expect(plan.panelWidth == 338)
    }

    @Test func onTheMirroredDisplayEverythingScalesAndThePictureKeepsItsShape() {
        let plan = ScreenPlan(size: Self.mirrored, panelReferenceWidth: Theme.metrics.panelWidth)
        #expect(abs(plan.unit - 1280.0 / 874.0) < 1e-9)
        #expect(abs(plan.pictureSize.width / plan.pictureSize.height - 4.0 / 3.0) < 1e-9)
        #expect(plan.pictureSize.height <= Self.mirrored.height)
        #expect(abs(plan.panelWidth - Theme.metrics.panelWidth * plan.unit) < 1e-9)
        #expect(abs(plan.pictureSize.width + plan.panelWidth - Self.mirrored.width) < 1e-9)
    }

    @Test(arguments: [phone, mirrored, CGSize(width: 932, height: 430), CGSize(width: 1024, height: 768),
                      CGSize(width: 1920, height: 1080), CGSize(width: 700, height: 700)])
    func thePictureIsNeverCroppedAndThePanelNeverStarved(size: CGSize) {
        for panel in [Theme.metrics.panelWidth, Theme.metrics.workingPanelWidth] {
            let plan = ScreenPlan(size: size, panelReferenceWidth: panel)
            #expect(abs(plan.pictureSize.width - plan.pictureSize.height * 4 / 3) < 1e-9)
            #expect(plan.pictureSize.height <= size.height + 1e-9)
            #expect(plan.panelWidth >= panel * plan.unit - 1e-9)
            #expect(abs(plan.pictureSize.width + plan.panelWidth - size.width) < 1e-9)
        }
    }

    @Test func theUnitIsTheTighterOfTheTwoFits() {
        #expect(ScreenPlan.unit(for: CGSize(width: 1748, height: 402)) == 1)
        #expect(ScreenPlan.unit(for: CGSize(width: 874, height: 804)) == 1)
        #expect(ScreenPlan.unit(for: CGSize(width: 1748, height: 804)) == 2)
    }

    @Test func aCollapsedWindowNeverAsksForZeroPointType() {
        #expect(ScreenPlan.unit(for: .zero) == Theme.metrics.minimumUnit)
        let plan = ScreenPlan(size: .zero, panelReferenceWidth: Theme.metrics.panelWidth)
        #expect(plan.pictureSize == .zero)
        #expect(plan.panelWidth == 0)
    }

    @Test func theShowWorkingPictureLeavesRoomForTheRows() {
        let plan = ScreenPlan(size: Self.phone, panelReferenceWidth: Theme.metrics.workingPanelWidth)
        #expect(plan.panelWidth == Theme.metrics.workingPanelWidth)
        #expect(plan.pictureSize.width == 874 - Theme.metrics.workingPanelWidth)
    }
}
