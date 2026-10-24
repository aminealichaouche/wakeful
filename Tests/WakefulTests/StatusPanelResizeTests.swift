import AppKit
import XCTest
@testable import Wakeful

/// Records the panel's height frame by frame while switching pages and reopening.
final class StatusPanelResizeTests: XCTestCase {
    private var controller: StatusPanelController!
    private var cleanupSettings: (() -> Void)!

    override func setUpWithError() throws {
        try XCTSkipIf(isRunningOnCI, "frame-timing test; shared CI runners are too slow to sample reliably")
        let settings: Settings
        (settings, cleanupSettings) = makeTestSettings()
        let manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()))
        controller = StatusPanelController(manager: manager, settings: settings, updater: UpdateChecker())
    }

    override func tearDown() {
        guard let controller else { return }
        controller.closePanel()
        spin(0.3)
        self.controller = nil
        cleanupSettings()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Panel heights sampled every 10ms.
    private func heights(for seconds: TimeInterval) -> [CGFloat] {
        var heights: [CGFloat] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            spin(0.01)
            heights.append(controller.panelFrame.height)
        }
        return heights
    }

    /// Reopening while Settings is showing must open straight at the Settings height, not at the
    /// main page's height first and then snap.
    func testReopeningOnSettingsOpensAtSettingsHeight() throws {
        controller.showPanel()
        spin(0.5)
        controller.navigation.page = .settings
        let settingsHeight = try XCTUnwrap(heights(for: 0.5).last)
        controller.closePanel()
        spin(0.4)

        controller.showPanel()
        let reopening = heights(for: 0.5)
        XCTAssertGreaterThan(settingsHeight, 0)
        XCTAssertEqual(reopening.max(), settingsHeight, "panel grew past the Settings height: \(reopening)")
        XCTAssertEqual(reopening.last, settingsHeight)
    }

    /// Going back to the main page grows the panel smoothly, never overshooting or snapping back.
    func testBackToMainGrowsSmoothly() throws {
        controller.navigation.page = .settings
        controller.showPanel()
        let settingsHeight = try XCTUnwrap(heights(for: 0.5).last)

        controller.navigation.page = .main
        let growing = heights(for: 0.5)
        let mainHeight = try XCTUnwrap(growing.last)
        XCTAssertGreaterThan(mainHeight, settingsHeight)
        XCTAssertEqual(growing, growing.sorted(), "height went back down while growing: \(growing)")
        XCTAssertGreaterThan(Set(growing).count, 3, "panel jumped instead of animating: \(growing)")
    }
}
