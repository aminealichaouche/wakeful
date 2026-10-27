import AppKit
import SwiftUI
import XCTest
@testable import Wakeful

/// Sessions started from a custom rule, driven by a fake system state.
final class RuleSessionTests: XCTestCase {
    private var settings: Wakeful.Settings!
    private var cleanupSettings: (() -> Void)!
    /// Read from the manager's background queue while tests change it, so it's behind a lock.
    private let lock = NSLock()
    private var _state = SystemSnapshot()
    private var _requested: [Set<RuleCondition.Kind>] = []
    private var state: SystemSnapshot {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    private var requested: [Set<RuleCondition.Kind>] { lock.withLock { _requested } }

    override func setUp() {
        (settings, cleanupSettings) = makeTestSettings()
        state = SystemSnapshot()
        lock.withLock { _requested = [] }
    }

    override func tearDown() {
        cleanupSettings()
    }

    private func makeManager(grace: TimeInterval) -> SessionManager {
        SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()),
                       ruleGracePeriod: grace) { [unowned self] kinds, apps in
            lock.withLock { _requested.append(kinds) }
            var snapshot = state
            if kinds.contains(.appRunning) { snapshot.runningBundleIDs = apps }
            return snapshot
        }
    }

    private let drive = MountedVolume(kind: .external, id: "UUID-T7", name: "T7", mountPoint: "/Volumes/T7")
    /// Two polls (every 2s) plus slack.
    private let pollWait = TimeInterval(SessionManager.rulePollInterval * 2) + 1.5

    func testSessionLastsWhileRuleHoldsAndEndsWhenItStops() {
        let manager = makeManager(grace: 0)
        defer { manager.end() }
        state.volumes = [drive]
        manager.start(.rule(CustomRule(conditions: [.externalDrive(nil)])))
        XCTAssertEqual(wakefulAssertionTypes(), [PowerAssertion.preventDisplaySleep])
        XCTAssertFalse(waitUntil(timeout: pollWait) { !manager.isActive }, "ended while the drive was connected")
        XCTAssertGreaterThanOrEqual(requested.count, 1)

        state.volumes = []   // drive unplugged
        XCTAssertTrue(waitUntil(timeout: pollWait) { !manager.isActive }, "outlived the drive")
        XCTAssertEqual(wakefulAssertionTypes(), [])
    }

    func testBriefDropWithinGracePeriodDoesNotEndSession() {
        let manager = makeManager(grace: 6)
        defer { manager.end() }
        state.volumes = [drive]
        manager.start(.rule(CustomRule(conditions: [.externalDrive(nil)])))
        state.volumes = []
        waitUntil(timeout: 3) { false }          // one unmet poll
        XCTAssertTrue(manager.isActive)
        state.volumes = [drive]                   // back before the grace period ends
        XCTAssertFalse(waitUntil(timeout: 7) { !manager.isActive }, "ended despite the drive coming back")
    }

    func testEndsAfterGracePeriod() {
        let manager = makeManager(grace: 3)
        defer { manager.end() }
        manager.start(.rule(CustomRule(conditions: [.charger])))   // unmet from the start
        let started = Date()
        XCTAssertTrue(waitUntil(timeout: 10) { !manager.isActive })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 3, "ended before the grace period")
    }

    func testAnyRuleKeepsGoingWhileOneConditionHolds() {
        let manager = makeManager(grace: 0)
        defer { manager.end() }
        state.onACPower = true
        manager.start(.rule(CustomRule(match: .any, conditions: [.charger, .externalDisplay])))
        state.onACPower = false
        state.externalDisplayConnected = true
        XCTAssertFalse(waitUntil(timeout: pollWait) { !manager.isActive })
        state.externalDisplayConnected = false
        XCTAssertTrue(waitUntil(timeout: pollWait) { !manager.isActive })
    }

    func testOnlyNeededStateIsGathered() {
        let manager = makeManager(grace: 0)
        defer { manager.end() }
        state.onACPower = true
        manager.start(.rule(CustomRule(conditions: [.charger])))
        XCTAssertTrue(waitUntil(timeout: pollWait) { !requested.isEmpty })
        XCTAssertEqual(requested.first, [.charger])
    }

    func testAppConditionUsesRunningApps() throws {
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let manager = makeManager(grace: 0)
        defer { manager.end() }
        manager.start(.rule(CustomRule(conditions: [.appRunning(AppChoice(bundleID: "com.apple.finder", name: "Finder"))])))
        XCTAssertFalse(waitUntil(timeout: pollWait) { !manager.isActive }, "Finder is running")
        _ = finder
        manager.start(.rule(CustomRule(conditions: [.appRunning(AppChoice(bundleID: "invalid.not.running", name: "Nope"))])))
        XCTAssertTrue(waitUntil(timeout: pollWait) { !manager.isActive })
    }

    func testReplacingRuleSessionIgnoresOldRule() {
        let manager = makeManager(grace: 0)
        defer { manager.end() }
        manager.start(.rule(CustomRule(conditions: [.charger])))   // would end at the first poll
        manager.start(.manual(until: nil))
        XCTAssertFalse(waitUntil(timeout: pollWait) { !manager.isActive }, "old rule ended the new session")
    }

    func testStressManyRuleSessions() {
        let manager = makeManager(grace: 0)
        defer { manager.end() }
        state.volumes = [drive]
        for i in 0..<500 {
            manager.start(.rule(CustomRule(match: i.isMultiple(of: 2) ? .all : .any, conditions: [.externalDrive(nil)])))
            if i.isMultiple(of: 3) { manager.end() }
        }
        XCTAssertLessThanOrEqual(wakefulAssertionTypes().count, 1)
        manager.end()
        XCTAssertEqual(wakefulAssertionTypes(), [])
    }
}

/// Rule sessions against the real system.
final class LiveRuleSessionTests: XCTestCase {
    private var attached: String?

    override func tearDown() {
        if let attached { shell("/usr/bin/hdiutil detach -force -quiet \"$1\"", [attached]) }
    }

    func testNetworkDriveRuleStaysActiveWhileShareIsMounted() throws {
        try XCTSkipIf(!Volumes.mounted().contains { $0.kind == .network }, "no network share mounted on this Mac")
        let (settings, cleanup) = makeTestSettings()
        defer { cleanup() }
        let manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()),
                                     ruleGracePeriod: 0)
        defer { manager.end() }
        manager.start(.rule(CustomRule(conditions: [.networkDrive(nil)])))
        XCTAssertFalse(waitUntil(timeout: 5) { !manager.isActive }, "ended while the share was mounted")
    }

    /// A mounted disk image must not keep an "external drive" session alive.
    func testDiskImageDoesNotSatisfyExternalDriveRule() throws {
        try XCTSkipIf(Volumes.mounted().contains { $0.kind == .external }, "a real external drive is connected")
        let name = "WakefulRule\(Int.random(in: 1000...9999))"
        let image = makeTempDirectory().appendingPathComponent("\(name).dmg").path
        XCTAssertEqual(shell("/usr/bin/hdiutil create -quiet -size 8m -fs APFS -volname \"$1\" \"$2\"", [name, image]).status, 0)
        XCTAssertEqual(shell("/usr/bin/hdiutil attach -quiet \"$1\"", [image]).status, 0)
        attached = "/Volumes/\(name)"

        let (settings, cleanup) = makeTestSettings()
        defer { cleanup() }
        let manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()),
                                     ruleGracePeriod: 0)
        defer { manager.end() }
        manager.start(.rule(CustomRule(conditions: [.externalDrive(nil)])))
        XCTAssertTrue(waitUntil(timeout: 5) { !manager.isActive }, "the disk image counted as an external drive")
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
