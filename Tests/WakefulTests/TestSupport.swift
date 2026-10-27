import Foundation
import IOKit.pwr_mgt
import XCTest
@testable import Wakeful

/// Settings backed by a throwaway defaults suite, with notifications off (they need an app bundle).
func makeTestSettings(file: StaticString = #filePath) -> (Settings, () -> Void) {
    let suite = "wakeful-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let settings = Settings(defaults: defaults)
    settings.notifyWhenSessionEnds = false
    return (settings, { defaults.removePersistentDomain(forName: suite) })
}

func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wakeful-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Power assertions held by `pid` (default: this process) with Wakeful's assertion name.
func wakefulAssertionTypes(pid: pid_t = getpid()) -> [String] {
    var unmanaged: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
          let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
    else { return [] }
    return (byProcess[NSNumber(value: pid)] ?? [])
        .filter { $0[kIOPMAssertionNameKey] as? String == "Wakeful session is active" }
        .compactMap { $0[kIOPMAssertionTypeKey] as? String }
}

/// Spins the main run loop until `condition` holds or `timeout` passes.
@discardableResult
func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return true
}

@discardableResult
func shell(_ command: String, _ arguments: [String] = []) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command, "sh"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// True when sudo works without a password for everything (e.g. GitHub's macOS runners), so
/// closed-display mode works even without Wakeful's helper.
var hasPasswordlessSudo: Bool {
    shell("/usr/bin/sudo -n /usr/bin/true").status == 0
}

/// True on CI, where shared runners are too slow for frame-timing tests.
var isRunningOnCI: Bool {
    ProcessInfo.processInfo.environment["CI"] == "true"
}

/// Current `pmset` SleepDisabled value (true = closed-display mode on).
func isSleepDisabled() -> Bool {
    shell("/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ {print $2}'").output
        .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
}

/// The menu, built the way the current edition builds it (the offline edition has no updater).
func makeMenuView(manager: SessionManager, settings: Settings, navigation: MenuNavigation) -> MenuView {
    #if OFFLINE
    MenuView(manager: manager, settings: settings, navigation: navigation)
    #else
    MenuView(manager: manager, settings: settings, updater: UpdateChecker(currentVersion: "1.2.0"), navigation: navigation)
    #endif
}

func makeStatusPanelController(manager: SessionManager, settings: Settings) -> StatusPanelController {
    #if OFFLINE
    StatusPanelController(manager: manager, settings: settings)
    #else
    StatusPanelController(manager: manager, settings: settings, updater: UpdateChecker())
    #endif
}
