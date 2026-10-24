import AppKit
import XCTest
@testable import Wakeful

final class SessionManagerTests: XCTestCase {
    private var settings: Settings!
    private var cleanupSettings: (() -> Void)!
    private var guardDirectory: URL!
    private var manager: SessionManager!

    override func setUp() {
        (settings, cleanupSettings) = makeTestSettings()
        guardDirectory = makeTempDirectory()
        manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: guardDirectory))
    }

    override func tearDown() {
        manager.end()
        XCTAssertEqual(wakefulAssertionTypes(), [], "assertions leaked")
        cleanupSettings()
        try? FileManager.default.removeItem(at: guardDirectory)
    }

    // MARK: - Basics

    func testIndefiniteSessionHoldsDisplayAssertionUntilEnded() {
        XCTAssertFalse(manager.isActive)
        manager.start(.manual(until: nil))
        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(wakefulAssertionTypes(), [PowerAssertion.preventDisplaySleep])

        manager.end()
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(wakefulAssertionTypes(), [])
    }

    func testAllowDisplaySleepSwitchesToSystemAssertion() {
        settings.allowDisplaySleep = true
        manager.start(.manual(until: nil))
        XCTAssertEqual(wakefulAssertionTypes(), [PowerAssertion.preventSystemSleep])

        settings.allowDisplaySleep = false
        manager.applyPowerSettings()
        XCTAssertEqual(wakefulAssertionTypes(), [PowerAssertion.preventDisplaySleep])
    }

    func testEndWithoutSessionIsHarmless() {
        manager.end()
        manager.end(reason: "nothing to end")
        XCTAssertTrue(manager.applyPowerSettings())
        XCTAssertEqual(wakefulAssertionTypes(), [])
    }

    func testClosedDisplayModeWithoutHelperFallsBackToAllowingSleep() throws {
        try XCTSkipIf(ClosedDisplayGuard.isHelperInstalled, "helper installed; covered by PmsetIntegrationTests")
        settings.allowSleepWhenDisplayClosed = false
        manager.start(.manual(until: nil))
        XCTAssertTrue(settings.allowSleepWhenDisplayClosed, "setting reverts when the helper is missing")
        XCTAssertFalse(isSleepDisabled())
    }

    // MARK: - Removing the closed-display helper

    func testCancellingHelperRemovalChangesNothing() {
        settings.allowSleepWhenDisplayClosed = false
        XCTAssertEqual(manager.removeClosedDisplayHelper { .cancelled }, .cancelled)
        XCTAssertFalse(settings.allowSleepWhenDisplayClosed, "Don't Allow must not turn the option off")
    }

    func testFailedHelperRemovalChangesNothing() {
        settings.allowSleepWhenDisplayClosed = false
        XCTAssertEqual(manager.removeClosedDisplayHelper { .failed }, .failed)
        XCTAssertFalse(settings.allowSleepWhenDisplayClosed, "a failed removal must not turn the option off")
    }

    func testSuccessfulHelperRemovalAllowsSleepAgain() {
        settings.allowSleepWhenDisplayClosed = false
        XCTAssertEqual(manager.removeClosedDisplayHelper { .succeeded }, .succeeded)
        XCTAssertTrue(settings.allowSleepWhenDisplayClosed)
    }

    func testHelperRemovalDoesNotTouchActiveSession() {
        manager.start(.manual(until: nil))
        for outcome: ClosedDisplayGuard.AdminOutcome in [.cancelled, .failed, .succeeded] {
            _ = manager.removeClosedDisplayHelper { outcome }
            XCTAssertTrue(manager.isActive)
            XCTAssertEqual(wakefulAssertionTypes(), [PowerAssertion.preventDisplaySleep])
        }
    }

    // MARK: - Timed sessions

    func testTimedSessionEndsOnItsOwn() {
        manager.start(.manual(until: Date().addingTimeInterval(1.5)))
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(waitUntil(timeout: 4) { !manager.isActive }, "timed session never ended")
        XCTAssertEqual(wakefulAssertionTypes(), [])
    }

    func testSessionWithPastEndDateEndsOnNextTick() {
        manager.start(.manual(until: Date().addingTimeInterval(-60)))
        XCTAssertTrue(waitUntil(timeout: 2.5) { !manager.isActive })
    }

    func testDistantFutureSessionStaysActive() {
        manager.start(.manual(until: .distantFuture))
        XCTAssertFalse(waitUntil(timeout: 1.5) { !manager.isActive })
        XCTAssertTrue(manager.session!.remainingDescription.hasSuffix("remaining"))
    }

    func testStartingNewSessionReplacesTimer() {
        manager.start(.manual(until: Date().addingTimeInterval(1)))
        manager.start(.manual(until: nil))
        XCTAssertFalse(waitUntil(timeout: 2.5) { !manager.isActive }, "old timer ended the new session")
        XCTAssertEqual(wakefulAssertionTypes().count, 1)
    }

    // MARK: - Download sessions

    func testDownloadSessionEndsWhenFileIsRenamed() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let partial = dir.appendingPathComponent("movie.mp4.crdownload")
        try Data(count: 1024).write(to: partial)

        manager.start(.download(DownloadWatcher(url: partial)))
        try FileManager.default.moveItem(at: partial, to: dir.appendingPathComponent("movie.mp4"))
        XCTAssertTrue(waitUntil(timeout: 7) { !manager.isActive }, "download session didn't end")
    }

    func testDownloadSessionEndsWhenStalled() throws {
        let file = makeTempDirectory().appendingPathComponent("stuck.part")
        try Data(count: 10).write(to: file)
        manager.start(.download(DownloadWatcher(url: file, stallTimeout: 1)))
        XCTAssertTrue(waitUntil(timeout: 7) { !manager.isActive }, "stalled download kept the Mac awake")
    }

    // MARK: - App sessions
    //
    // These simulate an app quitting by posting the workspace notification macOS sends, using
    // apps that are already running. Nothing is launched or terminated.

    func testAppSessionEndsWhenAppQuits() throws {
        let app = try XCTUnwrap(finder)
        manager.start(.app(app))
        XCTAssertEqual(manager.session?.triggerDescription, "While “\(app.localizedName!)” is running")
        XCTAssertFalse(waitUntil(timeout: 1) { !manager.isActive })

        postTermination(of: app)
        XCTAssertTrue(waitUntil(timeout: 2) { !manager.isActive }, "session outlived the app")
    }

    func testOtherAppsQuittingDoesNotEndSession() throws {
        manager.start(.app(try XCTUnwrap(finder)))
        postTermination(of: NSRunningApplication.current)
        postTermination(of: nil)
        XCTAssertFalse(waitUntil(timeout: 1.5) { !manager.isActive })
    }

    func testReplacedAppSessionStopsWatchingOldApp() throws {
        let app = try XCTUnwrap(finder)
        manager.start(.app(app))
        manager.start(.manual(until: nil))
        postTermination(of: app)
        XCTAssertFalse(waitUntil(timeout: 1.5) { !manager.isActive }, "old app observer ended the new session")
    }

    func testStressManyAppSessions() throws {
        let app = try XCTUnwrap(finder)
        for _ in 0..<300 {
            manager.start(.app(app))
            postTermination(of: app)
            XCTAssertTrue(waitUntil(timeout: 1) { !manager.isActive })
        }
        XCTAssertEqual(wakefulAssertionTypes(), [])
    }

    private var finder: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    }

    private func postTermination(of app: NSRunningApplication?) {
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: app.map { [NSWorkspace.applicationUserInfoKey: $0] }
        )
    }

    // MARK: - Stress

    func testStressRapidStartEnd() {
        let start = Date()
        for i in 0..<2_000 {
            manager.start(i.isMultiple(of: 2) ? .manual(until: nil) : .manual(until: Date().addingTimeInterval(60)))
            manager.end()
        }
        XCTAssertEqual(wakefulAssertionTypes(), [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 20, "2,000 cycles took too long")
    }

    func testStressReplacingSessionsKeepsExactlyOneAssertion() {
        for i in 0..<1_000 {
            manager.start(.manual(until: Date().addingTimeInterval(Double(i + 10))))
        }
        XCTAssertEqual(wakefulAssertionTypes().count, 1)
    }

    func testStressTogglingOptionsMidSession() {
        manager.start(.manual(until: nil))
        for _ in 0..<500 {
            settings.allowDisplaySleep.toggle()
            manager.applyPowerSettings()
            let expected = settings.allowDisplaySleep ? PowerAssertion.preventSystemSleep : PowerAssertion.preventDisplaySleep
            XCTAssertEqual(wakefulAssertionTypes(), [expected])
        }
    }

    func testStressNoSessionObjectsLeak() {
        weak var firstSession: Session?
        autoreleasepool {
            manager.start(.manual(until: nil))
            firstSession = manager.session
            for _ in 0..<500 {
                manager.start(.manual(until: nil))
            }
            manager.end()
        }
        XCTAssertNil(firstSession, "Session retained after it ended")
    }

    func testStressManyTimedSessionsAllExpire() {
        for _ in 0..<20 {
            manager.start(.manual(until: Date().addingTimeInterval(0.2)))
            XCTAssertTrue(waitUntil(timeout: 2.5) { !manager.isActive })
        }
        XCTAssertEqual(wakefulAssertionTypes(), [])
    }

    func testManagerDeallocationReleasesAssertion() {
        autoreleasepool {
            let temp = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: guardDirectory))
            temp.start(.manual(until: nil))
            XCTAssertEqual(wakefulAssertionTypes().count, 1)
            temp.end()
        }
        XCTAssertEqual(wakefulAssertionTypes(), [])
    }
}
