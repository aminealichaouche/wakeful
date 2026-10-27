import AppKit
import XCTest
@testable import Wakeful

/// The custom rule reacts to system changes right away instead of waiting for its next check.
/// Every test here uses a 60 second backup check, so anything faster came from a change event.
final class RuleReactionTests: XCTestCase {
    private var settings: Wakeful.Settings!
    private var cleanupSettings: (() -> Void)!
    private var manager: SessionManager!
    private var automation: RuleAutomation?
    private var attached: String?
    private let lock = NSLock()
    private var _state = SystemSnapshot()
    private var _checks = 0
    private var state: SystemSnapshot {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    private var checks: Int { lock.withLock { _checks } }
    private let drive = MountedVolume(kind: .external, id: "UUID-T7", name: "T7", mountPoint: "/Volumes/T7")
    private let share = MountedVolume(kind: .network, id: "nas.local/Everything", name: "Everything",
                                      mountPoint: "/Volumes/Everything")

    override func setUp() {
        (settings, cleanupSettings) = makeTestSettings()
        manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()))
        state = SystemSnapshot()
    }

    override func tearDown() {
        automation?.stop()
        automation = nil
        manager.end()
        cleanupSettings()
        if let attached { shell("/usr/bin/hdiutil detach -force -quiet \"$1\"", [attached]) }
    }

    /// Starts the automation with a fake system state, or the real one.
    private func start(_ rule: CustomRule, real: Bool = false, gracePeriod: TimeInterval? = nil,
                       checkDelay: TimeInterval = 0) {
        let automation = RuleAutomation(manager: manager, settings: settings, pollInterval: 60,
                                        gracePeriod: gracePeriod) { [unowned self] kinds, apps in
            if checkDelay > 0 { Thread.sleep(forTimeInterval: checkDelay) }
            lock.withLock { _checks += 1 }
            return real ? SystemSnapshot.capture(kinds, runningBundleIDs: apps) : state
        }
        settings.customRule = rule
        automation.start()
        self.automation = automation
        waitUntil(timeout: 0.3) { false }   // let the first check finish
    }

    private func post(_ name: Notification.Name, center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        center.post(name: name, object: nil)
    }

    // MARK: - Starting

    func testMountReactsImmediately() {
        start(CustomRule(conditions: [.externalDrive(nil)]))
        XCTAssertFalse(manager.isActive)
        state.volumes = [drive]
        let posted = Date()
        post(NSWorkspace.didMountNotification)
        XCTAssertTrue(waitUntil(timeout: 1) { manager.isActive }, "waited for the next check")
        print("Started \(Int(Date().timeIntervalSince(posted) * 1000))ms after the mount")
    }

    func testAppLaunchAndQuitReactImmediately() {
        start(CustomRule(conditions: [.charger]))
        state.onACPower = true
        post(NSWorkspace.didLaunchApplicationNotification)
        XCTAssertTrue(waitUntil(timeout: 1) { manager.isActive })
        state.onACPower = false
        post(NSWorkspace.didTerminateApplicationNotification)
        XCTAssertTrue(waitUntil(timeout: 1) { !manager.isActive })
    }

    func testDisplayChangeReactsImmediately() {
        start(CustomRule(conditions: [.externalDisplay]))
        state.externalDisplayConnected = true
        post(NSApplication.didChangeScreenParametersNotification, center: .default)
        XCTAssertTrue(waitUntil(timeout: 1) { manager.isActive })
    }

    /// A change that arrives while a check is running isn't lost.
    func testChangeDuringACheckIsNotLost() {
        start(CustomRule(conditions: [.externalDrive(nil)]), checkDelay: 0.4)
        waitUntil(timeout: 0.5) { false }
        post(NSWorkspace.didLaunchApplicationNotification)   // starts a slow check of the old state
        waitUntil(timeout: 0.1) { false }
        state.volumes = [drive]
        post(NSWorkspace.didMountNotification)                // arrives mid-check
        XCTAssertTrue(waitUntil(timeout: 2) { manager.isActive }, "the mount during a check was dropped")
    }

    // MARK: - Ending

    func testUnpluggingADriveEndsRightAway() {
        state.volumes = [drive]
        start(CustomRule(conditions: [.externalDrive(nil)]))
        XCTAssertTrue(waitUntil(timeout: 1) { manager.isActive })
        state.volumes = []
        let unplugged = Date()
        post(NSWorkspace.didUnmountNotification)
        XCTAssertTrue(waitUntil(timeout: 1) { !manager.isActive }, "drives have no grace period")
        XCTAssertLessThan(Date().timeIntervalSince(unplugged), 1)
    }

    /// Network shares get 5 seconds to come back, and the session ends as soon as that's over,
    /// not at the next (60s) check.
    func testNetworkShareGetsGracePeriodThenEndsOnTime() {
        state.volumes = [share]
        start(CustomRule(conditions: [.networkDrive(nil)]))
        XCTAssertTrue(waitUntil(timeout: 1) { manager.isActive })
        state.volumes = []
        let dropped = Date()
        post(NSWorkspace.didUnmountNotification)
        XCTAssertTrue(waitUntil(timeout: 7) { !manager.isActive })
        let elapsed = Date().timeIntervalSince(dropped)
        XCTAssertGreaterThanOrEqual(elapsed, RuleCondition.Kind.networkDrive.gracePeriod - 0.1)
        XCTAssertLessThan(elapsed, RuleCondition.Kind.networkDrive.gracePeriod + 1)
    }

    func testShareComingBackWithinGracePeriodKeepsSession() {
        state.volumes = [share]
        start(CustomRule(conditions: [.networkDrive(nil)]))
        XCTAssertTrue(waitUntil(timeout: 1) { manager.isActive })
        state.volumes = []
        post(NSWorkspace.didUnmountNotification)
        waitUntil(timeout: 2) { false }
        state.volumes = [share]
        post(NSWorkspace.didMountNotification)
        XCTAssertFalse(waitUntil(timeout: 5) { !manager.isActive }, "ended although the share came back")
    }

    /// Switching on a condition that's false ends the session at once: the grace period is for
    /// things dropping out on their own, not for edits.
    func testEditingTheRuleSkipsTheGracePeriod() {
        state.volumes = [share]
        let shareItem = CustomRule.Item(condition: .networkDrive(nil), isOn: true)
        start(CustomRule(match: .all, items: [shareItem, CustomRule.Item(condition: .audioPlaying, isOn: false)]))
        XCTAssertTrue(waitUntil(timeout: 1) { manager.isActive })

        let edited = Date()
        settings.customRule = CustomRule(match: .all, items: [shareItem, CustomRule.Item(condition: .audioPlaying, isOn: true)])
        XCTAssertTrue(waitUntil(timeout: 1) { !manager.isActive }, "waited out the grace period after an edit")
        XCTAssertLessThan(Date().timeIntervalSince(edited), 0.5)

        settings.customRule = CustomRule(match: .all, items: [shareItem, CustomRule.Item(condition: .audioPlaying, isOn: false)])
        XCTAssertTrue(waitUntil(timeout: 0.5) { manager.isActive }, "switching it back off didn't restart at once")

        // A share dropping out on its own still gets its grace period.
        state.volumes = []
        post(NSWorkspace.didUnmountNotification)
        XCTAssertFalse(waitUntil(timeout: 2) { !manager.isActive }, "no grace period for a real drop")
    }

    func testStressRapidToggling() {
        state.volumes = [share]
        let shareItem = CustomRule.Item(condition: .networkDrive(nil), isOn: true)
        start(CustomRule(match: .all, items: [shareItem]))
        XCTAssertTrue(waitUntil(timeout: 1) { manager.isActive })
        var slowest: TimeInterval = 0
        for i in 0..<100 {
            let audioOn = i.isMultiple(of: 2)
            let started = Date()
            settings.customRule = CustomRule(match: .all, items: [shareItem, CustomRule.Item(condition: .audioPlaying, isOn: audioOn)])
            XCTAssertTrue(waitUntil(timeout: 1) { manager.isActive == !audioOn }, "toggle \(i)")
            slowest = max(slowest, Date().timeIntervalSince(started))
        }
        print("Slowest of 100 toggles: \(Int(slowest * 1000))ms")
        XCTAssertLessThan(slowest, 0.5)
        XCTAssertLessThanOrEqual(wakefulAssertionTypes().count, 1)
    }

    func testGracePeriodsByCondition() {
        XCTAssertEqual(RuleCondition.Kind.networkDrive.gracePeriod, 5)
        XCTAssertEqual(RuleCondition.Kind.audioPlaying.gracePeriod, 5)
        for kind in [RuleCondition.Kind.externalDrive, .charger, .externalDisplay, .appRunning] {
            XCTAssertEqual(kind.gracePeriod, 0, "\(kind)")
        }
    }

    // MARK: - Watching only while needed

    func testWatchesChangesOnlyWhileRuleIsOn() {
        start(CustomRule(match: .all, items: [CustomRule.Item(condition: .charger, isOn: false)]))
        XCTAssertEqual(automation?.isWatchingChanges, false)
        let before = checks
        post(NSWorkspace.didMountNotification)
        waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(checks, before, "checked although nothing is switched on")

        settings.customRule = CustomRule(conditions: [.charger])
        XCTAssertTrue(waitUntil(timeout: 1) { self.automation?.isWatchingChanges == true })
        settings.customRule = CustomRule(match: .all, items: [CustomRule.Item(condition: .charger, isOn: false)])
        XCTAssertTrue(waitUntil(timeout: 1) { self.automation?.isWatchingChanges == false })
    }

    func testStopsReactingAfterStop() {
        start(CustomRule(conditions: [.externalDrive(nil)]))
        automation?.stop()
        let before = checks
        state.volumes = [drive]
        post(NSWorkspace.didMountNotification)
        waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(checks, before)
        XCTAssertFalse(manager.isActive)
    }

    // MARK: - Real events

    /// Mounting a real disk image fires a real mount event, which triggers a check right away.
    func testRealMountTriggersCheck() throws {
        start(CustomRule(conditions: [.externalDrive(nil)]), real: true)
        let before = checks
        let name = "WakefulReact\(Int.random(in: 1000...9999))"
        let image = makeTempDirectory().appendingPathComponent("\(name).dmg").path
        XCTAssertEqual(shell("/usr/bin/hdiutil create -quiet -size 8m -fs APFS -volname \"$1\" \"$2\"", [name, image]).status, 0)
        let mountStarted = Date()
        XCTAssertEqual(shell("/usr/bin/hdiutil attach -quiet \"$1\"", [image]).status, 0)
        attached = "/Volumes/\(name)"
        XCTAssertTrue(waitUntil(timeout: 2) { checks > before }, "the mount didn't trigger a check")
        print("Checked \(Int(Date().timeIntervalSince(mountStarted) * 1000))ms after starting the mount")
        if !Volumes.mounted().contains(where: { $0.kind == .external }) {
            XCTAssertFalse(manager.isActive, "a disk image isn't an external drive")
        }
    }

    /// Audio starting and stopping is picked up by CoreAudio listeners, not the backup check.
    func testRealAudioTriggersChecks() throws {
        try XCTSkipIf(isRunningOnCI, "CI runners have no audio output device")
        try XCTSkipIf(AudioOutput.isPlaying, "something else is already playing audio")
        start(CustomRule(conditions: [.audioPlaying]), real: true)
        XCTAssertFalse(manager.isActive)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0", "/System/Library/Sounds/Submarine.aiff"]
        try player.run()
        XCTAssertTrue(waitUntil(timeout: 1.5) { manager.isActive }, "audio starting wasn't noticed")
        player.waitUntilExit()
        // Audio has a 5 second grace period for pauses between songs.
        XCTAssertTrue(waitUntil(timeout: 8) { !manager.isActive }, "audio stopping wasn't noticed")
    }
}

final class SystemChangeMonitorTests: XCTestCase {
    func testStartStopAreSafeToRepeat() {
        var calls = 0
        let monitor = SystemChangeMonitor { calls += 1 }
        for _ in 0..<50 {
            monitor.start()
            monitor.start()
            monitor.stop()
            monitor.stop()
        }
        monitor.start()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        XCTAssertTrue(waitUntil(timeout: 0.5) { calls == 1 }, "expected exactly one callback per event, got \(calls)")
        monitor.stop()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(calls, 1, "called after stop")
    }

    func testReleasingARunningMonitorIsSafe() {
        var monitor: SystemChangeMonitor? = SystemChangeMonitor {}
        monitor?.start()
        monitor = nil
        // Events after it's gone must not reach freed memory.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didUnmountNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        waitUntil(timeout: 0.3) { false }
        XCTAssertNil(monitor)
    }
}
