import Foundation

/// Keeps the Mac awake with the lid closed by running `pmset -a disablesleep 1`.
///
/// Regular power assertions cannot stop clamshell sleep, and pmset needs root. Instead of asking
/// for a password every session (or storing it), a one-time setup installs a sudoers rule that
/// lets only the current user run exactly `pmset -a disablesleep 0` and `pmset -a disablesleep 1`
/// without a password. See `installHelper()`.
///
/// While enabled, a flag file exists and a small watchdog process restores normal sleep if
/// Wakeful exits without cleaning up (crash, force quit). If the Mac restarts mid-session, the
/// leftover flag is noticed and sleep is restored the next time Wakeful launches.
final class ClosedDisplayGuard {
    /// One file per user so a second account running setup can't replace the first one's rule.
    static var sudoersPath: String { "/etc/sudoers.d/wakeful-\(getuid())" }
    /// Location used by early builds (single file shared by all users).
    static let legacySudoersPath = "/etc/sudoers.d/wakeful"

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wakeful", isDirectory: true)
    }

    /// Result of an action that needs the admin password prompt.
    enum AdminOutcome {
        case succeeded
        /// The user dismissed the password prompt.
        case cancelled
        case failed
    }

    private let flagURL: URL
    private var watchdog: Process?
    private(set) var isEnabled = false

    init(directory: URL = ClosedDisplayGuard.defaultDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        flagURL = directory.appendingPathComponent("closed-display.flag")

        // A leftover flag means the previous run never restored sleep (e.g. the Mac restarted).
        if FileManager.default.fileExists(atPath: flagURL.path) {
            Self.setSleepDisabled(false)
            try? FileManager.default.removeItem(at: flagURL)
        }
    }

    // MARK: - One-time helper setup

    /// Whether the sudoers rule is installed. Checks the file itself: `sudo -l` would also match
    /// an admin's general `(ALL) ALL` rule and report a helper that isn't there.
    static var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
            || FileManager.default.fileExists(atPath: legacySudoersPath)
    }

    /// Installs the sudoers rule. Shows the macOS admin password prompt once.
    static func installHelper() -> AdminOutcome {
        let outcome = runAsAdmin(installScript(uid: getuid()),
                                 prompt: "Wakeful needs your password once to set up closed-display mode.")
        return outcome == .succeeded && !isHelperInstalled ? .failed : outcome
    }

    /// Removes the sudoers rule and makes sure normal sleep is restored.
    static func uninstallHelper() -> AdminOutcome {
        runAsAdmin("/usr/bin/pmset -a disablesleep 0; /bin/rm -f \(sudoersPath) \(legacySudoersPath)",
                   prompt: "Wakeful needs your password to remove the closed-display helper.")
    }

    /// The sudoers rule. `#uid` avoids quoting a user name, and spelling out the full argument
    /// lists means sudo allows exactly these two commands and nothing else.
    static func sudoersLines(uid: uid_t) -> [String] {
        [
            "# Installed by Wakeful: allows toggling closed-display mode without a password.",
            "# Remove with: sudo rm \(sudoersPath)",
            "#\(uid) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1",
        ]
    }

    /// Root script that writes the rule into a root-owned temp file, validates it with visudo, then
    /// moves it into place, so nothing user-writable is ever trusted.
    static func installScript(uid: uid_t) -> String {
        let lines = sudoersLines(uid: uid).map { "'\($0)'" }.joined(separator: " ")
        return "tmp=$(/usr/bin/mktemp /tmp/wakeful-sudoers.XXXXXX) && "
            + "printf '%s\\n' \(lines) > \"$tmp\" && "
            + "/usr/sbin/visudo -cqf \"$tmp\" && /usr/sbin/chown root:wheel \"$tmp\" && /bin/chmod 0440 \"$tmp\" && "
            + "/bin/mv -f \"$tmp\" \(sudoersPath) && /bin/rm -f \(legacySudoersPath)"
    }

    // MARK: - Enabling and disabling

    /// Returns false if the helper isn't installed, pmset failed or the watchdog couldn't start.
    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return true }
        guard FileManager.default.createFile(atPath: flagURL.path, contents: nil) else { return false }
        guard Self.setSleepDisabled(true), startWatchdog() else {
            // Never leave sleep disabled without crash protection.
            Self.setSleepDisabled(false)
            try? FileManager.default.removeItem(at: flagURL)
            return false
        }
        isEnabled = true
        return true
    }

    /// Restores normal sleep. Returns false if pmset failed; the flag is then kept so the next
    /// launch tries again.
    @discardableResult
    func disable() -> Bool {
        guard isEnabled else { return true }
        isEnabled = false
        guard Self.setSleepDisabled(false) else { return false }
        try? FileManager.default.removeItem(at: flagURL)
        return true
    }

    /// Records that sleep was already restored by other means (the uninstall script runs pmset as
    /// root), so no sudo call is needed or possible any more.
    func markRestored() {
        isEnabled = false
        try? FileManager.default.removeItem(at: flagURL)
    }

    /// Watchdog shell script. `$1` is the flag file, `$2` the PID to watch. It restores sleep if
    /// that process dies while the flag still exists, and exits quietly once the flag is removed.
    /// Comparing the process start time guards against the PID being reused by another process.
    static let watchdogScript = """
        started=$(/bin/ps -p "$2" -o lstart= 2>/dev/null)
        while [ -e "$1" ]; do
          if [ -z "$started" ] || [ "$(/bin/ps -p "$2" -o lstart= 2>/dev/null)" != "$started" ]; then
            /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0
            /bin/rm -f "$1"
            exit 0
          fi
          /bin/sleep 2
        done
        """

    private func startWatchdog() -> Bool {
        if let watchdog, watchdog.isRunning { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.watchdogScript, "wakeful-watchdog", flagURL.path,
                             String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        watchdog = process
        return true
    }

    // MARK: - Helpers

    @discardableResult
    private static func setSleepDisabled(_ disabled: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]) == 0
    }

    /// Runs a command and blocks until it exits. Deliberately avoids `waitUntilExit()`, which spins
    /// the run loop and would let session timers fire (and end the session) mid-call.
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return -1
        }
        exited.wait()
        return process.terminationStatus
    }

    /// An AppleScript string literal for `string`.
    static func appleScriptQuoted(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runAsAdmin(_ shellScript: String, prompt: String) -> AdminOutcome {
        let source = "do shell script \(appleScriptQuoted(shellScript)) with prompt \(appleScriptQuoted(prompt)) "
            + "with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return .succeeded }
        // -128 is AppleScript's "user cancelled".
        return error[NSAppleScript.errorNumber] as? Int == -128 ? .cancelled : .failed
    }
}
