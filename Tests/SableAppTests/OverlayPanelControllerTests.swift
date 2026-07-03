import AppKit
@testable import SableApp
import XCTest

final class OverlayPanelControllerTests: XCTestCase {
    func testSpotlightOriginCentersHorizontallyAndBiasesUpward() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelSize = NSSize(width: 668, height: 300)

        let origin = OverlayPanelController.spotlightOrigin(panelSize: panelSize, in: visibleFrame)

        XCTAssertEqual(origin.x, 386)
        XCTAssertEqual(origin.y, 408)
    }

    func testSpotlightOriginStaysInsideVisibleFrame() {
        let visibleFrame = NSRect(x: 50, y: 30, width: 640, height: 360)
        let panelSize = NSSize(width: 700, height: 420)

        let origin = OverlayPanelController.spotlightOrigin(panelSize: panelSize, in: visibleFrame)

        XCTAssertEqual(origin.x, 58)
        XCTAssertEqual(origin.y, 38)
    }
}
