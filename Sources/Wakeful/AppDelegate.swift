import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    lazy var manager = SessionManager(settings: settings)
    #if !OFFLINE
    let updater = UpdateChecker()
    #endif
    private var signalSources: [DispatchSourceSignal] = []
    private var statusPanel: StatusPanelController?
    private lazy var ruleAutomation = RuleAutomation(manager: manager, settings: settings)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Hides the Dock icon when running outside the app bundle (e.g. `swift run`).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitCleanlyOnSignals()
        #if OFFLINE
        statusPanel = StatusPanelController(manager: manager, settings: settings)
        #else
        statusPanel = StatusPanelController(manager: manager, settings: settings, updater: updater)
        #endif

        if settings.startSessionAtLaunch {
            manager.start(.manual(until: nil))
        }
        ruleAutomation.start()
        warmUpSensors()
        #if !OFFLINE
        updater.setAutomaticChecks(settings.checkForUpdatesAutomatically)
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Releases power assertions and reverts closed-display mode.
        manager.end()
    }

    /// The first audio and display queries take a moment (about 160ms for audio) while macOS sets
    /// them up. Doing that now, off the main thread, keeps the first rule toggle and the first
    /// opening of the rule page instant.
    private func warmUpSensors() {
        DispatchQueue.global(qos: .utility).async {
            _ = AudioOutput.isPlaying
            _ = Displays.isExternalDisplayConnected
            _ = Volumes.mounted()
        }
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
