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

/// Current `pmset` SleepDisabled value (true = closed-display mode on).
func isSleepDisabled() -> Bool {
    shell("/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ {print $2}'").output
        .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
}
