import AppKit
import XCTest
@testable import Wakeful

/// Clicking the menu bar icon must toggle the panel, even when that same click first reaches the
/// panel as an outside click or focus loss.
final class StatusPanelToggleTests: XCTestCase {
    private var controller: StatusPanelController!
    private var cleanupSettings: (() -> Void)!

    override func setUp() {
        let settings: Settings
        (settings, cleanupSettings) = makeTestSettings()
        let manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()))
        controller = makeStatusPanelController(manager: manager, settings: settings)
    }

    override func tearDown() {
        controller.closePanel()
        controller = nil
        cleanupSettings()
    }

    func testIconClickOpensAndCloses() {
        controller.togglePanel()
        XCTAssertTrue(controller.isPanelVisible)
        controller.togglePanel()
        XCTAssertFalse(controller.isPanelVisible)
        controller.togglePanel()
        XCTAssertTrue(controller.isPanelVisible)
    }

    func testIconClickThatAlreadyClosedThePanelDoesNotReopenIt() {
        controller.togglePanel()
        controller.closePanelAutomatically() // the click is seen as "outside" first
        controller.togglePanel()             // then the icon's action runs
        XCTAssertFalse(controller.isPanelVisible, "panel reopened instead of closing")
    }

    func testIconClickLaterAfterClickingElsewhereOpens() {
        controller.togglePanel()
        controller.closePanelAutomatically()
        waitUntil(timeout: StatusPanelController.sameClickInterval + 0.2) { false }
        controller.togglePanel()
        XCTAssertTrue(controller.isPanelVisible)
    }

    func testAutomaticCloseWhenAlreadyClosedDoesNotSwallowNextClick() {
        controller.closePanelAutomatically()
        controller.togglePanel()
        XCTAssertTrue(controller.isPanelVisible)
    }

    func testStressManyToggles() {
        for i in 1...200 {
            controller.togglePanel()
            XCTAssertEqual(controller.isPanelVisible, !i.isMultiple(of: 2))
        }
    }

    /// With keyboard navigation on, a focused control would show a blue ring as soon as the menu opens.
    func testOpensWithNothingFocused() {
        controller.showPanel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let responder = controller.panelFirstResponder
        XCTAssertTrue(responder == nil || responder is NSWindow, "focused: \(String(describing: responder))")
    }
}
