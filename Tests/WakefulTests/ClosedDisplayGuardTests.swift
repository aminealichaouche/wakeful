import Foundation
import XCTest
@testable import Wakeful

/// Tests that never change system power settings.
final class ClosedDisplayGuardTests: XCTestCase {
    // MARK: - AppleScript quoting (the only path into the admin shell)

    func testAppleScriptQuotingRoundTripsHostileStrings() throws {
        let hostile = [
            "plain",
            "\"",
            "\\",
            "\\\"",
            "\" & (do shell script \"touch /tmp/pwned\") & \"",
            "end\" \n do shell script \"id",
            "'; rm -rf / #",
            "$(touch /tmp/pwned) `id`",
            "tab\tnew\nline\rcr",
            "unicode “quotes” ‘single’ ¬ ∞ 😀",
            "",
        ]
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab\"\\'$`;&|<>()\n\t ¬“”")
        let random = (0..<300).map { _ in
            String((0..<Int.random(in: 0...40, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
        }
        for string in hostile + random {
            let source = "return \(ClosedDisplayGuard.appleScriptQuoted(string))"
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            XCTAssertNil(error, "failed to compile quoted \(string.debugDescription)")
            XCTAssertEqual(result?.stringValue, string, string.debugDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/pwned"))
    }

    // MARK: - Sudoers rule

    func testSudoersRuleIsValidAndMinimal() throws {
        let lines = ClosedDisplayGuard.sudoersLines(uid: getuid())
        let rules = lines.filter { !$0.hasPrefix("# ") }
        XCTAssertEqual(rules, ["#\(getuid()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"])
        XCTAssertFalse(lines.joined().contains("'"), "a single quote would break the install script")

        let file = makeTempDirectory().appendingPathComponent("rule")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let check = shell("/usr/sbin/visudo -cf \"$1\"", [file.path])
        XCTAssertEqual(check.status, 0, check.output)
    }

    func testRuleForOtherUIDsIsAlsoValid() throws {
        for uid: uid_t in [0, 1, 501, 502, 65_534, 2_147_483_647] {
            let file = makeTempDirectory().appendingPathComponent("rule")
            try ClosedDisplayGuard.sudoersLines(uid: uid).joined(separator: "\n").appending("\n")
                .write(to: file, atomically: true, encoding: .utf8)
            XCTAssertEqual(shell("/usr/sbin/visudo -cqf \"$1\"", [file.path]).status, 0, "uid \(uid)")
        }
    }

    func testInstallScriptSyntaxAndOutput() throws {
        let script = ClosedDisplayGuard.installScript(uid: getuid())
        XCTAssertEqual(shell("/bin/sh -n -c \"$1\"", [script]).status, 0, "syntax error in install script")
        XCTAssertTrue(script.contains("/usr/sbin/visudo -cqf"), "rule must be validated before install")
        XCTAssertTrue(script.contains("/bin/mv -f \"$tmp\" /etc/sudoers.d/wakeful-\(getuid())"), "per-user rule file")

        // Run only the user-safe part (write + validate) and compare what would be installed.
        let prefix = try XCTUnwrap(script.components(separatedBy: " && /usr/sbin/chown").first)
        let result = shell(prefix + " && cat \"$tmp\" && rm -f \"$tmp\"")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, ClosedDisplayGuard.sudoersLines(uid: getuid()).joined(separator: "\n") + "\n")
    }

    func testInstalledRuleOnlyAllowsTheTwoCommands() throws {
        try XCTSkipUnless(ClosedDisplayGuard.isHelperInstalled, "helper not installed on this Mac")
        let path = FileManager.default.fileExists(atPath: ClosedDisplayGuard.sudoersPath)
            ? ClosedDisplayGuard.sudoersPath : ClosedDisplayGuard.legacySudoersPath
        let attributes = shell("/usr/bin/stat -f '%Su:%Sg %Lp' \"$1\"", [path]).output
        XCTAssertEqual(attributes.trimmingCharacters(in: .whitespacesAndNewlines), "root:wheel 440")

        // The password-free entries sudo reports for this user must be exactly the two pmset commands.
        let listing = shell("/usr/bin/sudo -n -l").output
        let passwordFree = listing.components(separatedBy: "\n")
            .filter { $0.contains("NOPASSWD") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(passwordFree.contains("(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"),
                      listing)
        XCTAssertEqual(passwordFree.filter { $0.contains("pmset") }.count, 1, listing)

        // Actually try harmless commands that must be refused without a password.
        for denied in [
            "/usr/bin/id -u",
            "/bin/sh -c 'id -u'",
            "/usr/bin/pmset -g",
            "/usr/bin/pmset -a disablesleep 0 -g",
            "/usr/bin/pmset -a disablesleep 2",
            "/usr/bin/pmset",
        ] {
            let result = shell("/usr/bin/sudo -n \(denied)")
            XCTAssertNotEqual(result.status, 0, "ran as root without a password: \(denied)")
        }
        XCTAssertEqual(shell("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0").status, 0,
                       "the allowed command itself must work")
    }

    // MARK: - Flag file and watchdog

    func testLeftoverFlagIsClearedOnLaunch() {
        let dir = makeTempDirectory()
        let flag = dir.appendingPathComponent("closed-display.flag")
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        _ = ClosedDisplayGuard(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path))
        XCTAssertFalse(isSleepDisabled())
    }

    func testEnableFailsCleanlyWithoutHelper() throws {
        try XCTSkipIf(ClosedDisplayGuard.isHelperInstalled, "helper installed; covered by PmsetIntegrationTests")
        let dir = makeTempDirectory()
        let guardian = ClosedDisplayGuard(directory: dir)
        XCTAssertFalse(guardian.enable())
        XCTAssertFalse(guardian.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("closed-display.flag").path))
    }

    func testDisableWhenNotEnabledIsHarmless() {
        let guardian = ClosedDisplayGuard(directory: makeTempDirectory())
        for _ in 0..<100 { guardian.disable() }
        XCTAssertFalse(guardian.isEnabled)
    }

    func testWatchdogExitsWhenFlagRemoved() throws {
        let flag = makeTempDirectory().appendingPathComponent("flag")
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        let watchdog = try startWatchdog(flag: flag, pid: getpid())
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(watchdog.isRunning)
        try FileManager.default.removeItem(at: flag)
        XCTAssertTrue(waitUntil(timeout: 5) { !watchdog.isRunning }, "watchdog kept running")
    }

    func testWatchdogRestoresWhenOwnerDies() throws {
        let flag = makeTempDirectory().appendingPathComponent("flag")
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        let owner = try startProcess("/bin/sleep", ["60"])
        let watchdog = try startWatchdog(flag: flag, pid: owner.processIdentifier)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(watchdog.isRunning)
        owner.terminate()
        XCTAssertTrue(waitUntil(timeout: 5) { !watchdog.isRunning })
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path), "restore branch didn't run")
        XCTAssertFalse(isSleepDisabled())
    }

    func testWatchdogRestoresImmediatelyForMissingOwner() throws {
        let flag = makeTempDirectory().appendingPathComponent("flag")
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        let watchdog = try startWatchdog(flag: flag, pid: 99_999_999)
        XCTAssertTrue(waitUntil(timeout: 3) { !watchdog.isRunning })
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path))
    }

    /// The flag path and PID are passed as arguments, never pasted into the script.
    func testWatchdogArgumentsCannotInject() throws {
        let dir = makeTempDirectory()
        let marker = dir.appendingPathComponent("pwned")
        let evil = dir.appendingPathComponent("a\"; touch '\(marker.path)'; \"$(touch \(marker.path))`touch \(marker.path)`")
        FileManager.default.createFile(atPath: evil.path, contents: nil)
        let watchdog = try startWatchdog(flag: evil, pid: getpid(), pidString: "1; touch \(marker.path)")
        XCTAssertTrue(waitUntil(timeout: 4) { !watchdog.isRunning })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "watchdog executed injected text")
    }

    func testStressManyWatchdogsAllExit() throws {
        let dir = makeTempDirectory()
        var watchdogs: [Process] = []
        for i in 0..<50 {
            let flag = dir.appendingPathComponent("flag\(i)")
            FileManager.default.createFile(atPath: flag.path, contents: nil)
            watchdogs.append(try startWatchdog(flag: flag, pid: getpid()))
        }
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .forEach { try FileManager.default.removeItem(at: $0) }
        XCTAssertTrue(waitUntil(timeout: 6) { watchdogs.allSatisfy { !$0.isRunning } })
    }

    // MARK: - Helpers

    private func startWatchdog(flag: URL, pid: pid_t, pidString: String? = nil) throws -> Process {
        try startProcess("/bin/sh", ["-c", ClosedDisplayGuard.watchdogScript, "wakeful-watchdog",
                                     flag.path, pidString ?? String(pid)])
    }

    private func startProcess(_ path: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
