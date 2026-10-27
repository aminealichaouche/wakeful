import AppKit
import SwiftUI
import XCTest
@testable import Wakeful

/// The panel must grow and shrink with the rule page as conditions are added and removed,
/// instead of cutting the bottom off.
final class RulePagePanelTests: XCTestCase {
    private var settings: Wakeful.Settings!
    private var cleanupSettings: (() -> Void)!
    private var manager: SessionManager!
    private var controller: StatusPanelController!

    override func setUp() {
        (settings, cleanupSettings) = makeTestSettings()
        manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()))
        controller = makeStatusPanelController(manager: manager, settings: settings)
    }

    override func tearDown() {
        controller.closePanel()
        waitUntil(timeout: 0.3) { false }
        controller = nil
        manager.end()
        cleanupSettings()
    }

    /// The rule page's own height, measured separately.
    private func ruleContentHeight() -> CGFloat {
        let navigation = MenuNavigation()
        navigation.page = .rule
        let host = NSHostingView(rootView: makeMenuView(manager: manager, settings: settings, navigation: navigation)
            .fixedSize(horizontal: false, vertical: true))
        host.frame.size = CGSize(width: MenuView.width, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func item(_ condition: RuleCondition, _ isOn: Bool = false) -> CustomRule.Item {
        CustomRule.Item(condition: condition, isOn: isOn)
    }

    func testPanelFollowsConditionsBeingAddedAndRemoved() {
        controller.showPanel()
        controller.navigation.page = .rule
        waitUntil(timeout: 0.8) { false }
        let empty = controller.panelFrame.height
        XCTAssertEqual(empty, ruleContentHeight(), accuracy: 2)

        var heights = [empty]
        let steps: [[CustomRule.Item]] = [
            [item(.charger)],
            [item(.charger), item(.externalDrive(nil))],
            [item(.charger, true), item(.externalDrive(nil)), item(.networkDrive(nil), true), item(.audioPlaying)],
            [item(.charger)],
            [],
        ]
        for items in steps {
            settings.customRule = CustomRule(match: .all, items: items)
            waitUntil(timeout: 0.8) { false }
            let expected = ruleContentHeight()
            XCTAssertEqual(controller.panelFrame.height, expected, accuracy: 2,
                           "panel doesn't fit the page with \(items.count) conditions (cut off or gap)")
            heights.append(controller.panelFrame.height)
        }
        XCTAssertGreaterThan(heights[3], heights[1], "didn't grow as conditions were added")
        XCTAssertEqual(heights.last!, empty, accuracy: 2, "didn't shrink back")
    }

    func testOpeningOnRulePageFitsSavedRule() {
        settings.customRule = CustomRule(match: .any, items: [item(.charger, true), item(.externalDrive(nil)),
                                                             item(.externalDisplay), item(.audioPlaying, true)])
        controller.navigation.page = .rule
        controller.showPanel()
        waitUntil(timeout: 0.8) { false }
        XCTAssertEqual(controller.panelFrame.height, ruleContentHeight(), accuracy: 2)
    }
}
