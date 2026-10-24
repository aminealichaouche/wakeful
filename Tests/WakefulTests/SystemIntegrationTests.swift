import AppKit
import XCTest
@testable import Wakeful

/// Really toggles `pmset disablesleep`. Opt in with WAKEFUL_PMSET_TESTS=1; needs the helper installed.
/// Every test restores normal sleep afterwards.
final class PmsetIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAKEFUL_PMSET_TESTS"] == "1",
                          "set WAKEFUL_PMSET_TESTS=1 to run")
        try XCTSkipUnless(ClosedDisplayGuard.isHelperInstalled, "closed-display helper not installed")
    }

    override func tearDown() {
        shell("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0")
        XCTAssertFalse(isSleepDisabled())
    }

    func testEnableAndDisable() {
        let guardian = ClosedDisplayGuard(directory: makeTempDirectory())
        XCTAssertTrue(guardian.enable())
        XCTAssertTrue(isSleepDisabled())
        guardian.disable()
        XCTAssertFalse(isSleepDisabled())
    }

    func testStressRapidToggling() {
        let guardian = ClosedDisplayGuard(directory: makeTempDirectory())
        for _ in 0..<25 {
            XCTAssertTrue(guardian.enable())
            XCTAssertTrue(isSleepDisabled())
            guardian.disable()
            XCTAssertFalse(isSleepDisabled())
        }
    }

    func testSessionManagerRestoresSleepWhenSessionEnds() {
        let (settings, cleanup) = makeTestSettings()
        defer { cleanup() }
        settings.allowSleepWhenDisplayClosed = false
        let manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()))

        manager.start(.manual(until: Date().addingTimeInterval(1.5)))
        XCTAssertTrue(isSleepDisabled())
        XCTAssertTrue(waitUntil(timeout: 4) { !manager.isActive })
        XCTAssertFalse(isSleepDisabled(), "timed session left closed-display mode on")

        manager.start(.manual(until: nil))
        manager.start(.manual(until: nil)) // replacing keeps it on
        XCTAssertTrue(isSleepDisabled())
        settings.allowSleepWhenDisplayClosed = true
        manager.applyPowerSettings()
        XCTAssertFalse(isSleepDisabled(), "turning the option off mid-session didn't restore sleep")
        manager.end()
    }

    func testCancelledOrFailedHelperRemovalKeepsClosedDisplayModeOn() {
        let (settings, cleanup) = makeTestSettings()
        defer { cleanup() }
        settings.allowSleepWhenDisplayClosed = false
        let manager = SessionManager(settings: settings, closedDisplayGuard: ClosedDisplayGuard(directory: makeTempDirectory()))
        manager.start(.manual(until: nil))
        XCTAssertTrue(isSleepDisabled())

        for outcome: ClosedDisplayGuard.AdminOutcome in [.cancelled, .failed] {
            _ = manager.removeClosedDisplayHelper { outcome }
            XCTAssertFalse(settings.allowSleepWhenDisplayClosed)
            XCTAssertTrue(isSleepDisabled(), "closed-display mode turned off after \(outcome)")
        }
        manager.end()
        XCTAssertFalse(isSleepDisabled())
    }

    /// Simulates a crash: closed-display mode is on and the owning process is SIGKILLed.
    func testWatchdogRestoresSleepAfterCrash() throws {
        let flag = makeTempDirectory().appendingPathComponent("flag")
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        XCTAssertEqual(shell("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1").status, 0)
        XCTAssertTrue(isSleepDisabled())

        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["60"]
        try owner.run()
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", ClosedDisplayGuard.watchdogScript, "wakeful-watchdog", flag.path,
                              String(owner.processIdentifier)]
        try watchdog.run()
        Thread.sleep(forTimeInterval: 0.5)

        kill(owner.processIdentifier, SIGKILL)
        XCTAssertTrue(waitUntil(timeout: 5) { !isSleepDisabled() }, "sleep stayed disabled after crash")
    }
}

/// Launches the built Wakeful.app and quits it every possible way, checking that the session is
/// always turned off. Opt in with WAKEFUL_APP_TESTS=1 after running scripts/build-app.sh.
final class AppQuitTests: XCTestCase {
    private static let bundleID = "io.github.wakeful"
    private var appURL: URL!
    private var savedDefaults: [String: Any] = [:]
    private var testsClosedDisplay = false

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAKEFUL_APP_TESTS"] == "1",
                          "set WAKEFUL_APP_TESTS=1 to run")
        appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/Wakeful.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: appURL.path), "run scripts/build-app.sh first")
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty,
                      "quit Wakeful before running these tests")

        let defaults = UserDefaults(suiteName: Self.bundleID)!
        for key in ["startSessionAtLaunch", "allowSleepWhenDisplayClosed", "notifyWhenSessionEnds"] {
            savedDefaults[key] = defaults.object(forKey: key)
        }
        testsClosedDisplay = ClosedDisplayGuard.isHelperInstalled
        defaults.set(true, forKey: "startSessionAtLaunch")
        defaults.set(!testsClosedDisplay, forKey: "allowSleepWhenDisplayClosed")
        defaults.set(false, forKey: "notifyWhenSessionEnds")
        defaults.synchronize()
    }

    override func tearDown() {
        guard let defaults = UserDefaults(suiteName: Self.bundleID) else { return }
        for (key, value) in savedDefaults {
            if value is NSNull { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
        }
        for key in ["startSessionAtLaunch", "allowSleepWhenDisplayClosed", "notifyWhenSessionEnds"]
        where savedDefaults[key] == nil {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).forEach { $0.forceTerminate() }
        if testsClosedDisplay { shell("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0") }
    }

    func testQuitMenuButtonPath() throws {
        // The X button calls NSApp.terminate, the same path as a standard Quit request.
        try runQuitScenario("Quit request") { $0.terminate() }
    }

    func testSIGTERM() throws { try runQuitScenario("SIGTERM") { kill($0.processIdentifier, SIGTERM) } }
    func testSIGINT() throws { try runQuitScenario("SIGINT") { kill($0.processIdentifier, SIGINT) } }
    func testSIGHUP() throws { try runQuitScenario("SIGHUP") { kill($0.processIdentifier, SIGHUP) } }
    func testForceQuitSIGKILL() throws { try runQuitScenario("SIGKILL") { $0.forceTerminate() } }

    func testStressRepeatedLaunchAndQuit() throws {
        for i in 0..<5 {
            try runQuitScenario("cycle \(i)") { $0.terminate() }
        }
    }

    private func runQuitScenario(_ name: String, quit: (NSRunningApplication) -> Void) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        var launched: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { launched = $0; launchError = $1 }
        XCTAssertTrue(waitUntil(timeout: 15) { launched != nil || launchError != nil })
        let app = try XCTUnwrap(launched, "\(name): launch failed: \(String(describing: launchError))")
        let pid = app.processIdentifier

        XCTAssertTrue(waitUntil(timeout: 15) { !wakefulAssertionTypes(pid: pid).isEmpty },
                      "\(name): session never started")
        if testsClosedDisplay {
            XCTAssertTrue(waitUntil(timeout: 5) { isSleepDisabled() }, "\(name): closed-display mode never turned on")
        }

        quit(app)

        XCTAssertTrue(waitUntil(timeout: 10) { app.isTerminated }, "\(name): app didn't quit")
        XCTAssertTrue(waitUntil(timeout: 5) { wakefulAssertionTypes(pid: pid).isEmpty },
                      "\(name): keep-awake assertion survived quitting")
        if testsClosedDisplay {
            XCTAssertTrue(waitUntil(timeout: 6) { !isSleepDisabled() },
                          "\(name): closed-display mode stayed on after quitting")
        }
    }
}
