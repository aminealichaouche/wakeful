import AppKit
import SwiftUI
import XCTest
@testable import Wakeful

/// The custom rule running automatically, driven by a fake system state.
final class RuleAutomationTests: XCTestCase {
    private var settings: Wakeful.Settings!
    private var cleanupSettings: (() -> Void)!
    private var manager: SessionManager!
    private var automation: RuleAutomation?
    /// Read from the automation's background queue while tests change it, so it's behind a lock.
    private let lock = NSLock()
    private var _state = SystemSnapshot()
    private var _requested: [Set<RuleCondition.Kind>] = []
    private var state: SystemSnapshot {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    private var requested: [Set<RuleCondition.Kind>] { lock.withLock { _requested } }

    private static let poll: TimeInterval = 0.2
    /// A few checks' worth of time.
    private let settle: TimeInterval = 1.2
    private let drive = MountedVolume(kind: .external, id: "UUID-T7", name: "T7", mountPoint: "/Volumes/T7")

    override func setUp() {
        (settings, cleanupSettings) = makeTestSettings()
        manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()))
        state = SystemSnapshot()
        lock.withLock { _requested = [] }
    }

    override func tearDown() {
        automation?.stop()
        automation = nil
        manager.end()
        XCTAssertEqual(wakefulAssertionTypes(), [], "assertion leaked")
        cleanupSettings()
    }

    private func startAutomation(grace: TimeInterval = 0) {
        let automation = RuleAutomation(manager: manager, settings: settings, pollInterval: Self.poll,
                                        gracePeriod: grace) { [unowned self] kinds, apps in
            lock.withLock { _requested.append(kinds) }
            var snapshot = state
            if kinds.contains(.appRunning) { snapshot.runningBundleIDs = apps }
            return snapshot
        }
        automation.start()
        self.automation = automation
    }

    private func rule(_ items: [(RuleCondition, Bool)], match: CustomRule.Match = .all) -> CustomRule {
        CustomRule(match: match, items: items.map { CustomRule.Item(condition: $0.0, isOn: $0.1) })
    }

    private var isRuleSession: Bool {
        if case .rule = manager.session?.trigger { return true }
        return false
    }

    // MARK: - Off until switched on

    func testNothingHappensUntilAConditionIsOn() {
        state.volumes = [drive]
        settings.customRule = rule([(.externalDrive(nil), false), (.charger, false)])
        startAutomation()
        XCTAssertFalse(waitUntil(timeout: settle) { manager.isActive }, "started with every condition off")
        XCTAssertTrue(requested.isEmpty, "checked the system with nothing switched on")
    }

    func testTurningAConditionOnStartsSessionWhenTrue() {
        state.volumes = [drive]
        settings.customRule = rule([(.externalDrive(nil), false)])
        startAutomation()
        settings.customRule = rule([(.externalDrive(nil), true)])
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession }, "didn't start")
        XCTAssertEqual(manager.session?.triggerDescription, "While an external drive is connected")
        XCTAssertEqual(wakefulAssertionTypes(), [PowerAssertion.preventDisplaySleep])
    }

    func testOffConditionsAreIgnored() {
        state.onACPower = false
        state.volumes = [drive]
        // The charger is off, so only the drive counts, even with "all".
        settings.customRule = rule([(.externalDrive(nil), true), (.charger, false)])
        startAutomation()
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession })
        XCTAssertEqual(manager.session?.triggerDescription, "While an external drive is connected")
    }

    func testTurningEverythingOffEndsTheSession() {
        state.volumes = [drive]
        settings.customRule = rule([(.externalDrive(nil), true)])
        startAutomation(grace: 60)
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession })
        settings.customRule = rule([(.externalDrive(nil), false)])
        XCTAssertTrue(waitUntil(timeout: settle) { !manager.isActive }, "kept running after being switched off")
    }

    // MARK: - Starting and stopping on its own

    func testEndsWhenRuleStopsBeingTrueAndRestartsWhenTrueAgain() {
        state.volumes = [drive]
        settings.customRule = rule([(.externalDrive(nil), true)])
        startAutomation()
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession })
        state.volumes = []   // drive unplugged
        XCTAssertTrue(waitUntil(timeout: settle) { !manager.isActive }, "outlived the drive")
        state.volumes = [drive]   // plugged back in
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession }, "didn't start again")
    }

    func testBriefDropWithinGracePeriodDoesNotEndSession() {
        state.volumes = [drive]
        settings.customRule = rule([(.externalDrive(nil), true)])
        startAutomation(grace: 2)
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession })
        state.volumes = []
        waitUntil(timeout: 1) { false }
        XCTAssertTrue(manager.isActive)
        state.volumes = [drive]
        XCTAssertFalse(waitUntil(timeout: 3) { !manager.isActive }, "ended despite the drive coming back")
    }

    func testEndsAfterGracePeriod() {
        state.onACPower = true
        settings.customRule = rule([(.charger, true)])
        startAutomation(grace: 1.5)
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession })
        state.onACPower = false
        let unplugged = Date()
        XCTAssertTrue(waitUntil(timeout: 5) { !manager.isActive })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(unplugged), 1.5, "ended before the grace period")
    }

    func testAllAndAny() {
        state.onACPower = true
        settings.customRule = rule([(.charger, true), (.externalDisplay, true)], match: .all)
        startAutomation()
        XCTAssertFalse(waitUntil(timeout: settle) { manager.isActive }, "all: only one is true")
        settings.customRule = rule([(.charger, true), (.externalDisplay, true)], match: .any)
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession }, "any: one is enough")
        XCTAssertEqual(manager.session?.triggerDescription,
                       "While the charger is connected or an external display is connected")
    }

    func testEditingTheRuleUpdatesTheRunningSession() {
        state.volumes = [drive]
        state.onACPower = true
        settings.customRule = rule([(.externalDrive(nil), true), (.charger, false)])
        startAutomation()
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession })
        settings.customRule = rule([(.externalDrive(nil), true), (.charger, true)])
        XCTAssertTrue(waitUntil(timeout: settle) {
            manager.session?.triggerDescription == "While an external drive is connected and the charger is connected"
        })
        XCTAssertTrue(isRuleSession)
    }

    // MARK: - Working alongside the user

    func testNeverReplacesASessionStartedByHand() {
        manager.start(.manual(until: nil))
        state.volumes = [drive]
        settings.customRule = rule([(.externalDrive(nil), true)])
        startAutomation()
        waitUntil(timeout: settle) { false }
        XCTAssertFalse(isRuleSession, "replaced the manual session")
        // When the manual session ends and the rule is still true, the rule takes over.
        manager.end()
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession })
    }

    func testDoesNotEndASessionStartedByHand() {
        state.volumes = []
        settings.customRule = rule([(.externalDrive(nil), true)])
        startAutomation()
        manager.start(.manual(until: nil))
        XCTAssertFalse(waitUntil(timeout: settle) { !manager.isActive }, "ended the manual session")
    }

    func testEndingItYourselfKeepsItOffUntilTheRuleResets() {
        state.volumes = [drive]
        settings.customRule = rule([(.externalDrive(nil), true)])
        startAutomation()
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession })

        manager.end()   // the user turns it off
        XCTAssertFalse(waitUntil(timeout: settle) { manager.isActive }, "restarted right after being turned off")
        XCTAssertTrue(automation!.isSuppressed)

        state.volumes = []   // rule stops being true…
        XCTAssertTrue(waitUntil(timeout: settle) { automation?.isSuppressed == false })
        state.volumes = [drive]   // …and becomes true again
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession }, "didn't come back once the rule reset")
    }

    // MARK: - Details

    func testOnlyNeededStateIsGathered() {
        state.onACPower = true
        settings.customRule = rule([(.charger, true), (.externalDrive(nil), false)])
        startAutomation()
        XCTAssertTrue(waitUntil(timeout: settle) { !requested.isEmpty })
        XCTAssertEqual(requested.first, [.charger], "looked at switched-off conditions")
    }

    func testAppConditionUsesRunningApps() {
        settings.customRule = rule([(.appRunning(AppChoice(bundleID: "com.apple.finder", name: "Finder")), true)])
        startAutomation()
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession }, "Finder is running")
        XCTAssertEqual(manager.session?.triggerDescription, "While “Finder” is running")
        settings.customRule = rule([(.appRunning(AppChoice(bundleID: "invalid.not.running", name: "Nope")), true)])
        XCTAssertTrue(waitUntil(timeout: settle) { !manager.isActive })
    }

    func testStressSwitchingOnAndOff() {
        state.volumes = [drive]
        startAutomation()
        for i in 0..<300 {
            settings.customRule = rule([(.externalDrive(nil), i.isMultiple(of: 2)), (.charger, false)])
            if i.isMultiple(of: 7) { waitUntil(timeout: 0.02) { false } }
        }
        // Ends switched off (299 is odd).
        XCTAssertTrue(waitUntil(timeout: settle) { !manager.isActive })
        XCTAssertEqual(wakefulAssertionTypes(), [])
        settings.customRule = rule([(.externalDrive(nil), true)])
        XCTAssertTrue(waitUntil(timeout: settle) { isRuleSession })
        XCTAssertEqual(wakefulAssertionTypes().count, 1)
    }
}

/// The custom rule running against the real system.
final class LiveRuleAutomationTests: XCTestCase {
    private var attached: String?
    private var settings: Wakeful.Settings!
    private var cleanupSettings: (() -> Void)!
    private var manager: SessionManager!
    private var automation: RuleAutomation!

    override func setUp() {
        (settings, cleanupSettings) = makeTestSettings()
        manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()))
        automation = RuleAutomation(manager: manager, settings: settings, pollInterval: 0.3, gracePeriod: 0)
    }

    override func tearDown() {
        automation.stop()
        manager.end()
        cleanupSettings()
        if let attached { shell("/usr/bin/hdiutil detach -force -quiet \"$1\"", [attached]) }
    }

    func testMountedNetworkShareTurnsRuleOn() throws {
        try XCTSkipIf(!Volumes.mounted().contains { $0.kind == .network }, "no network share mounted on this Mac")
        settings.customRule = CustomRule(conditions: [.networkDrive(nil)])
        automation.start()
        XCTAssertTrue(waitUntil(timeout: 3) { manager.isActive }, "didn't start with a share mounted")
        XCTAssertFalse(waitUntil(timeout: 3) { !manager.isActive }, "ended while the share was mounted")
    }

    /// A mounted disk image must not turn on an "external drive" rule.
    func testDiskImageDoesNotTurnOnExternalDriveRule() throws {
        try XCTSkipIf(Volumes.mounted().contains { $0.kind == .external }, "a real external drive is connected")
        let name = "WakefulRule\(Int.random(in: 1000...9999))"
        let image = makeTempDirectory().appendingPathComponent("\(name).dmg").path
        XCTAssertEqual(shell("/usr/bin/hdiutil create -quiet -size 8m -fs APFS -volname \"$1\" \"$2\"", [name, image]).status, 0)
        XCTAssertEqual(shell("/usr/bin/hdiutil attach -quiet \"$1\"", [image]).status, 0)
        attached = "/Volumes/\(name)"

        settings.customRule = CustomRule(conditions: [.externalDrive(nil)])
        automation.start()
        XCTAssertFalse(waitUntil(timeout: 3) { manager.isActive }, "the disk image counted as an external drive")
    }
}

/// The real sensors behind the conditions.
final class RuleSensorTests: XCTestCase {
    func testChargerMatchesBatteryState() {
        if let battery = Battery.status() {
            // On a laptop: "on AC" is the opposite of "on battery".
            XCTAssertEqual(PowerSource.isOnACPower, !battery.onBattery)
        } else {
            XCTAssertTrue(PowerSource.isOnACPower, "Macs without a battery always run on AC")
        }
    }

    func testDisplayCheckDoesNotCrash() {
        _ = Displays.isExternalDisplayConnected
        let external = NSScreen.screens.contains {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) == 0 } ?? false
        }
        if external { XCTAssertTrue(Displays.isExternalDisplayConnected, "an active external screen is connected") }
    }

    /// Plays a system sound at zero volume, so nothing is heard.
    func testDetectsAudioPlaying() throws {
        try XCTSkipIf(isRunningOnCI, "CI runners have no audio output device")
        try XCTSkipIf(AudioOutput.isPlaying, "something else is already playing audio")
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0", "/System/Library/Sounds/Submarine.aiff"]
        try player.run()
        XCTAssertTrue(waitUntil(timeout: 2) { AudioOutput.isPlaying }, "playback not detected")
        player.waitUntilExit()
        XCTAssertTrue(waitUntil(timeout: 4) { !AudioOutput.isPlaying }, "still reported playing after it stopped")
    }

    func testFullSnapshotIsQuick() {
        let start = Date()
        for _ in 0..<50 {
            _ = SystemSnapshot.capture(Set(RuleCondition.Kind.allCases), runningBundleIDs: [])
        }
        let elapsed = Date().timeIntervalSince(start)
        print("50 full snapshots took \(String(format: "%.2f", elapsed))s")
        XCTAssertLessThan(elapsed, 5)
    }
}

final class EditionTests: XCTestCase {
    func testEditionMatchesBuildFlag() {
        #if OFFLINE
        XCTAssertTrue(Edition.isOffline)
        XCTAssertTrue(Edition.aboutText.contains("Offline"))
        #else
        XCTAssertFalse(Edition.isOffline)
        #endif
    }

    /// The menu builds and lays out in this edition, with and without a session.
    func testMenuLaysOutInThisEdition() {
        let (settings, cleanup) = makeTestSettings()
        defer { cleanup() }
        let manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()))
        defer { manager.end() }
        let navigation = MenuNavigation()
        let host = NSHostingView(rootView: makeMenuView(manager: manager, settings: settings, navigation: navigation))
        for page in [MenuView.Page.main, .settings, .rule] {
            navigation.page = page
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 100, "\(page)")
        }
    }
}
