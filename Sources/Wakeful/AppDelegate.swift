import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    lazy var manager = SessionManager(settings: settings)
    let updater = UpdateChecker()
    private var signalSources: [DispatchSourceSignal] = []
    private var statusPanel: StatusPanelController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Hides the Dock icon when running outside the app bundle (e.g. `swift run`).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitCleanlyOnSignals()
        statusPanel = StatusPanelController(manager: manager, settings: settings, updater: updater)

        if settings.startSessionAtLaunch {
            manager.start(.manual(until: nil))
        }
        updater.setAutomaticChecks(settings.checkForUpdatesAutomatically)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Releases power assertions and reverts closed-display mode.
        manager.end()
    }

    /// `kill`, Ctrl-C and hang-ups would otherwise exit without running `applicationWillTerminate`.
    /// (SIGKILL can't be caught; the OS drops the assertions and the watchdog restores sleep.)
    private func quitCleanlyOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
