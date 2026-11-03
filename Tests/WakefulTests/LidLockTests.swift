import AppKit
import XCTest
@testable import Wakeful

/// "Lock Mac When Lid Is Closed". The lock itself is replaced by a counter, so these never lock
/// the Mac running them.
final class LidLockTests: XCTestCase {
    private var settings: Wakeful.Settings!
    private var cleanupSettings: (() -> Void)!
    private var manager: SessionManager!
    private var locks = 0
    private var lidLock: LidLock!

    override func setUp() {
        (settings, cleanupSettings) = makeTestSettings()
        manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()))
        locks = 0
        lidLock = LidLock(manager: manager, settings: settings) { [unowned self] in locks += 1 }
        lidLock.lidChanged(isClosed: false)   // start from an open lid
    }

    override func tearDown() {
        lidLock.stop()
        manager.end()
        cleanupSettings()
    }

    func testOffByDefault() {
        XCTAssertFalse(settings.lockWhenLidClosed)
        manager.start(.manual(until: nil))
        lidLock.lidChanged(isClosed: true)
        XCTAssertEqual(locks, 0)
    }

    func testLocksWhenLidClosesDuringSession() {
        settings.lockWhenLidClosed = true
        manager.start(.manual(until: nil))
        lidLock.lidChanged(isClosed: true)
        XCTAssertEqual(locks, 1)
    }

    func testOnlyDuringASession() {
        settings.lockWhenLidClosed = true
        lidLock.lidChanged(isClosed: true)
        XCTAssertEqual(locks, 0, "locked with no session running")
    }

    func testWorksForEverySessionKind() {
        settings.lockWhenLidClosed = true
        for trigger: SessionTrigger in [.manual(until: nil), .manual(until: Date().addingTimeInterval(600)),
                                        .rule(CustomRule(conditions: [.charger]))] {
            manager.start(trigger)
            lidLock.lidChanged(isClosed: true)
            lidLock.lidChanged(isClosed: false)
        }
        XCTAssertEqual(locks, 3)
    }

    func testOpeningNeverLocks() {
        settings.lockWhenLidClosed = true
        manager.start(.manual(until: nil))
        for _ in 0..<5 { lidLock.lidChanged(isClosed: false) }
        XCTAssertEqual(locks, 0)
    }

    func testRepeatedClosedMessagesLockOnce() {
        settings.lockWhenLidClosed = true
        manager.start(.manual(until: nil))
        for _ in 0..<5 { lidLock.lidChanged(isClosed: true) }
        XCTAssertEqual(locks, 1)
        lidLock.lidChanged(isClosed: false)
        lidLock.lidChanged(isClosed: true)
        XCTAssertEqual(locks, 2, "closing again after opening should lock again")
    }

    func testLidAlreadyClosedAtLaunchDoesNotLock() {
        settings.lockWhenLidClosed = true
        manager.start(.manual(until: nil))
        let fresh = LidLock(manager: manager, settings: settings) { [unowned self] in locks += 1 }
        fresh.lidChanged(isClosed: true)    // what it learns first
        fresh.lidChanged(isClosed: true)    // a repeat while still closed
        XCTAssertLessThanOrEqual(locks, 1)
        // Started with a closed lid (as here, with an external display): the next closed message
        // is not a new close.
        if LidMonitor.isLidClosed == true {
            let launched = LidLock(manager: manager, settings: settings) { [unowned self] in locks += 100 }
            launched.start()
            launched.lidChanged(isClosed: true)
            launched.stop()
            XCTAssertLessThan(locks, 100, "locked because the lid was already closed at launch")
        }
    }

    func testTurningTheOptionOffMidSessionStopsLocking() {
        settings.lockWhenLidClosed = true
        manager.start(.manual(until: nil))
        settings.lockWhenLidClosed = false
        lidLock.lidChanged(isClosed: true)
        XCTAssertEqual(locks, 0)
    }

    // MARK: - The real system

    func testClamshellMessageConstant() {
        // iokit_family_msg(sub_iokit_powermanagement, 0x100) = sys_iokit | sub_iokit_powermanagement | 0x100
        let sysIOKit: UInt32 = (0x38 & 0x3f) << 26
        let subPowerManagement: UInt32 = (13 & 0xfff) << 14
        XCTAssertEqual(LidMonitor.clamshellStateChange, sysIOKit | subPowerManagement | 0x100)
    }

    func testReadsLidStateOnLaptops() {
        // nil only on Macs without a lid.
        if Battery.status() != nil {
            XCTAssertNotNil(LidMonitor.isLidClosed, "a laptop should report its lid state")
        }
    }

    func testListensForLidChanges() {
        let monitor = LidMonitor { _ in }
        for _ in 0..<20 {
            monitor.start()
            XCTAssertTrue(monitor.isRunning, "couldn't register for lid notifications")
            monitor.start()
            monitor.stop()
            monitor.stop()
            XCTAssertFalse(monitor.isRunning)
        }
        lidLock.start()
        XCTAssertTrue(lidLock.isWatching)
        lidLock.stop()
        XCTAssertFalse(lidLock.isWatching)
    }

    func testReleasingARunningMonitorIsSafe() {
        var monitor: LidMonitor? = LidMonitor { _ in }
        monitor?.start()
        monitor = nil
        XCTAssertNil(monitor)
    }

    /// Checks the system lock function can be found, without calling it.
    func testSystemLockFunctionIsAvailable() {
        XCTAssertTrue(ScreenLock.canLockDirectly, "Lock Screen's function wasn't found; Wakeful would fall back to the screen saver")
    }

    func testToggleIconExists() {
        XCTAssertNotNil(NSImage(systemSymbolName: "lock.laptopcomputer", accessibilityDescription: nil))
    }
}
