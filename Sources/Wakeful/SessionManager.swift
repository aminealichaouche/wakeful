import AppKit
import Combine

/// What keeps a session alive.
enum SessionTrigger {
    /// Started from the menu; ends at `until`, or never if nil.
    case manual(until: Date?)
    /// Ends when the app quits.
    case app(NSRunningApplication)
    /// Ends when the download finishes or stalls.
    case download(DownloadWatcher)
    /// Ends once the rule has stopped being met for a few seconds.
    case rule(CustomRule)
}

final class Session {
    let trigger: SessionTrigger
    let startedAt = Date()

    init(trigger: SessionTrigger) {
        self.trigger = trigger
    }

    var endDate: Date? {
        if case .manual(let until) = trigger { return until }
        return nil
    }

    /// What's keeping the session going, or nil for a session started by hand (the time line
    /// already says everything there is to say).
    var triggerDescription: String? {
        switch trigger {
        case .manual:
            return nil
        case .app(let app):
            return "While “\(app.localizedName ?? "App")” is running"
        case .download(let watcher):
            return "While “\(watcher.url.lastPathComponent)” is downloading"
        case .rule(let rule):
            return "While \(rule.summary)"
        }
    }

    var remainingDescription: String {
        switch trigger {
        case .manual(let until?):
            return "\(Format.duration(until.timeIntervalSinceNow)) remaining"
        case .manual(nil):
            return "On until you turn it off"
        case .app, .download, .rule:
            // The line below says what the session is waiting for.
            return "Active"
        }
    }
}

/// Owns the active session and the power assertions that implement it.
final class SessionManager: ObservableObject {
    private let settings: Settings
    private let closedDisplayGuard: ClosedDisplayGuard

    @Published private(set) var session: Session?
    private var assertion: PowerAssertion?
    private var ticker: Timer?
    private var tickCount = 0
    private var terminationObserver: NSObjectProtocol?
    /// Download polling walks the file tree, so it runs off the main thread.
    private let downloadPollQueue = DispatchQueue(label: "io.github.wakeful.download-poll")
    private var isPollingDownload = false
    private var startedScreenSaverForCurrentIdle = false
    /// Rule checks list mounted volumes and query audio devices, so they also run off the main thread.
    private let rulePollQueue = DispatchQueue(label: "io.github.wakeful.rule-poll")
    private var isPollingRule = false
    private var ruleUnmetSince: Date?
    private let snapshotProvider: (Set<RuleCondition.Kind>, Set<String>) -> SystemSnapshot
    /// How long a rule may be unmet before its session ends, so a drive or share that drops for a
    /// moment (a NAS reconnecting) doesn't end it.
    let ruleGracePeriod: TimeInterval
    static let rulePollInterval = 2

    init(settings: Settings, closedDisplayGuard: ClosedDisplayGuard = ClosedDisplayGuard(),
         ruleGracePeriod: TimeInterval = 5,
         snapshotProvider: @escaping (Set<RuleCondition.Kind>, Set<String>) -> SystemSnapshot = SystemSnapshot.capture) {
        self.settings = settings
        self.closedDisplayGuard = closedDisplayGuard
        self.ruleGracePeriod = ruleGracePeriod
        self.snapshotProvider = snapshotProvider
    }

    var isActive: Bool { session != nil }

    func start(_ trigger: SessionTrigger) {
        stopWatchingTriggers()
        ruleUnmetSince = nil
        session = Session(trigger: trigger)

        if case .app(let app) = trigger {
            terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let quit = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if quit?.processIdentifier == app.processIdentifier {
                    self?.end(reason: "“\(app.localizedName ?? "The app")” quit.")
                }
            }
        }

        if settings.notifyWhenSessionEnds {
            Notifier.requestAuthorization()
        }
        applyPowerSettings()
        startTicker()
    }

    /// Ends the session. When `reason` is given and notifications are enabled, the user is notified.
    func end(reason: String? = nil) {
        guard session != nil else { return }
        stopWatchingTriggers()
        session = nil
        assertion?.release()
        assertion = nil
        let restoredSleep = closedDisplayGuard.disable()

        if let reason, settings.notifyWhenSessionEnds {
            Notifier.post(title: "Wakeful session ended", body: reason)
        }
        if !restoredSleep {
            Notifier.post(title: "Wakeful couldn't restore sleep",
                          body: "Your Mac may stay awake with the lid closed. Run: sudo pmset -a disablesleep 0")
        }
    }

    /// Brings assertions in line with the current settings. Call after changing a setting.
    ///
    /// Returns false if closed-display mode was requested but couldn't be enabled (e.g. the helper
    /// isn't installed); the setting is then reverted to allow sleep.
    @discardableResult
    func applyPowerSettings() -> Bool {
        guard isActive else { return true }

        let type = settings.allowDisplaySleep ? PowerAssertion.preventSystemSleep : PowerAssertion.preventDisplaySleep
        if assertion?.type != type {
            assertion?.release()
            assertion = PowerAssertion(type: type, reason: "Wakeful session is active")
        }

        if settings.allowSleepWhenDisplayClosed {
            if !closedDisplayGuard.disable() {
                Notifier.post(title: "Wakeful couldn't restore sleep",
                              body: "Your Mac may stay awake with the lid closed. Run: sudo pmset -a disablesleep 0")
            }
        } else if !closedDisplayGuard.enable() {
            settings.allowSleepWhenDisplayClosed = true
            return false
        }
        return true
    }

    /// Turns closed-display mode on or off, running the one-time helper setup first if needed.
    func setAllowSleepWhenDisplayClosed(_ allow: Bool) {
        if !allow, !ClosedDisplayGuard.isHelperInstalled {
            guard Dialogs.confirmHelperInstall() else { return }
            switch ClosedDisplayGuard.installHelper() {
            case .succeeded:
                break
            case .cancelled:
                return
            case .failed:
                Dialogs.showError("Closed-display mode couldn't be set up.")
                return
            }
        }
        settings.allowSleepWhenDisplayClosed = allow
        if !applyPowerSettings() {
            Dialogs.showError("Closed-display mode couldn't be enabled.")
        }
    }

    /// Removes the one-time helper. Settings only change if removal succeeds: cancelling the
    /// password prompt or a failure leaves closed-display mode exactly as it was.
    func removeClosedDisplayHelper(
        uninstall: () -> ClosedDisplayGuard.AdminOutcome = ClosedDisplayGuard.uninstallHelper
    ) -> ClosedDisplayGuard.AdminOutcome {
        let outcome = uninstall()
        guard outcome == .succeeded else { return outcome }
        // The uninstall script restored sleep as root and the sudo rule is gone, so closed-display
        // mode can't stay on.
        closedDisplayGuard.markRestored()
        settings.allowSleepWhenDisplayClosed = true
        return outcome
    }

    // MARK: - Periodic checks

    private func startTicker() {
        ticker?.invalidate()
        tickCount = 0
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        // .common so the timer keeps firing while the status menu is open.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopWatchingTriggers() {
        ticker?.invalidate()
        ticker = nil
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        terminationObserver = nil
    }

    private func tick() {
        guard let session else { return }
        tickCount += 1

        if let endDate = session.endDate, endDate <= Date() {
            end(reason: "The timer finished.")
            return
        }

        if case .download(let watcher) = session.trigger, tickCount % 5 == 0 {
            pollDownload(watcher, for: session)
        }

        if case .rule(let rule) = session.trigger, tickCount % Self.rulePollInterval == 0 {
            pollRule(rule, for: session)
        }

        if settings.lowBatteryThreshold > 0, tickCount % 15 == 0,
           let battery = Battery.status(), battery.onBattery, battery.percent <= settings.lowBatteryThreshold {
            end(reason: "Battery dropped to \(battery.percent)%.")
            return
        }

        checkScreenSaver()
    }

    private func pollDownload(_ watcher: DownloadWatcher, for polledSession: Session) {
        guard !isPollingDownload else { return }
        isPollingDownload = true
        downloadPollQueue.async { [weak self] in
            let state = watcher.poll()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isPollingDownload = false
                // Ignore results for a session that was replaced or ended meanwhile.
                guard session === polledSession else { return }
                switch state {
                case .finished:
                    end(reason: "“\(watcher.url.lastPathComponent)” finished downloading.")
                case .stalled:
                    end(reason: "“\(watcher.url.lastPathComponent)” stopped downloading.")
                case .downloading:
                    break
                }
            }
        }
    }

    private func pollRule(_ rule: CustomRule, for polledSession: Session) {
        guard !isPollingRule else { return }
        isPollingRule = true
        let kinds = rule.watchedKinds
        let apps = kinds.contains(.appRunning) ? SystemSnapshot.runningBundleIDs() : []
        let provider = snapshotProvider
        rulePollQueue.async { [weak self] in
            let snapshot = provider(kinds, apps)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isPollingRule = false
                guard session === polledSession else { return }
                ruleChecked(rule, snapshot)
            }
        }
    }

    private func ruleChecked(_ rule: CustomRule, _ snapshot: SystemSnapshot) {
        if rule.isMet(in: snapshot) {
            ruleUnmetSince = nil
            return
        }
        let now = Date()
        let since = ruleUnmetSince ?? now
        ruleUnmetSince = since
        guard now.timeIntervalSince(since) >= ruleGracePeriod else { return }
        let unmet = rule.conditions.first { !$0.isMet(in: snapshot) }
        end(reason: unmet.map { "No longer true: \($0.phrase)." } ?? "The rule is no longer met.")
    }

    /// The display assertion also suppresses the screen saver, so when the user allows it we
    /// start it ourselves once they've been idle long enough.
    private func checkScreenSaver() {
        guard settings.allowScreenSaver, !settings.allowDisplaySleep else { return }
        let idle = UserIdle.seconds
        if idle < 5 {
            startedScreenSaverForCurrentIdle = false
        } else if !startedScreenSaverForCurrentIdle, idle >= TimeInterval(settings.screenSaverDelayMinutes * 60) {
            startedScreenSaverForCurrentIdle = true
            ScreenSaver.start()
        }
    }
}

enum Format {
    /// "1h 05m 09s", "12m 03s", "42s"
    static func duration(_ interval: TimeInterval) -> String {
        guard !interval.isNaN, interval > 0 else { return "0s" }
        // Cap before converting so absurd values can't trap in Int(_:).
        let total = Int(min(interval, 99_999 * 3600).rounded(.up))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return String(format: "%dh %02dm %02ds", hours, minutes, seconds) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, seconds) }
        return "\(seconds)s"
    }
}
