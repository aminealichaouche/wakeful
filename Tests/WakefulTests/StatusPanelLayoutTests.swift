import AppKit
import XCTest
@testable import Wakeful

final class StatusPanelLayoutTests: XCTestCase {
    /// A 1440×900 screen with a 24pt menu bar.
    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 876)
    private let icon = NSRect(x: 900, y: 876, width: 24, height: 24)

    /// The panel must stay attached to the menu bar however tall its content gets.
    func testTopEdgeStaysPinnedForAnyHeight() {
        for height in stride(from: 100.0, through: 800.0, by: 37.0) {
            let frame = StatusPanelController.panelFrame(contentSize: CGSize(width: 300, height: height),
                                                         below: icon, in: visible)
            XCTAssertEqual(frame.maxY, icon.minY - StatusPanelController.gapBelowMenuBar, "height \(height)")
            XCTAssertEqual(frame.height, height)
            XCTAssertEqual(frame.minX, icon.minX)
        }
    }

    func testStaysOnScreenNearRightEdge() {
        let farRight = NSRect(x: 1430, y: 876, width: 24, height: 24)
        let frame = StatusPanelController.panelFrame(contentSize: CGSize(width: 300, height: 400), below: farRight, in: visible)
        XCTAssertEqual(frame.maxX, visible.maxX - StatusPanelController.screenMargin)
    }

    func testStaysOnScreenNearLeftEdge() {
        let farLeft = NSRect(x: -20, y: 876, width: 24, height: 24)
        let frame = StatusPanelController.panelFrame(contentSize: CGSize(width: 300, height: 400), below: farLeft, in: visible)
        XCTAssertEqual(frame.minX, visible.minX + StatusPanelController.screenMargin)
    }

    func testTallContentIsLimitedToScreen() {
        let frame = StatusPanelController.panelFrame(contentSize: CGSize(width: 300, height: 5_000), below: icon, in: visible)
        XCTAssertEqual(frame.minY, visible.minY + StatusPanelController.screenMargin)
        XCTAssertEqual(frame.maxY, icon.minY - StatusPanelController.gapBelowMenuBar)
    }

    /// Secondary displays have non-zero origins.
    func testSecondaryDisplayWithOffsetOrigin() {
        let secondVisible = NSRect(x: 1440, y: -200, width: 1920, height: 1055)
        let secondIcon = NSRect(x: 3000, y: 855, width: 24, height: 24)
        let frame = StatusPanelController.panelFrame(contentSize: CGSize(width: 300, height: 500), below: secondIcon, in: secondVisible)
        XCTAssertEqual(frame.maxY, secondIcon.minY - StatusPanelController.gapBelowMenuBar)
        XCTAssertTrue(secondVisible.contains(frame))
    }
}
