import AppKit
import Combine

/// Runs the custom rule. While any of its conditions is switched on, it checks the rule the moment
/// something relevant changes (see `SystemChangeMonitor`), and every few seconds as a backup, and
/// keeps a session going whenever the rule is met:
///
/// - Rule met and nothing else running: starts a session.
/// - Rule no longer met: ends that session, right away for most conditions, or after a few
///   seconds for network shares and audio, which drop out briefly on their own (a NAS
///   reconnecting, a pause between songs).
/// - A session started by hand is never replaced or ended.
/// - If you end (or replace) a rule session yourself, it stays off until the rule next stops being
///   met, instead of starting again a moment later.
final class RuleAutomation {
    static let defaultPollInterval: TimeInterval = 2

    private let manager: SessionManager
    private let settings: Settings
    private let pollInterval: TimeInterval
    /// Overrides each condition's own grace period (tests use this).
    let gracePeriod: TimeInterval?
    private let snapshotProvider: (Set<RuleCondition.Kind>, Set<String>) -> SystemSnapshot
    /// Rule checks list mounted volumes and query audio devices, so they run off the main thread.
    private let queue = DispatchQueue(label: "io.github.wakeful.rule-automation")

    private var timer: Timer?
    private var subscriptions: [AnyCancellable] = []
    private var isChecking = false
    /// Something changed while a check was running, so its result may already be out of date.
    private var needsAnotherCheck = false
    private var unmetSince: Date?
    private lazy var changes = SystemChangeMonitor { [weak self] in self?.check() }
    /// Set when the user ends or replaces a rule session; cleared once the rule stops being met.
    private(set) var isSuppressed = false
    /// True while this class itself starts or ends a session, so it isn't mistaken for the user.
    private var isChangingSession = false
    private var lastSession: Session?

    init(manager: SessionManager, settings: Settings,
         pollInterval: TimeInterval = RuleAutomation.defaultPollInterval,
         gracePeriod: TimeInterval? = nil,
         snapshotProvider: @escaping (Set<RuleCondition.Kind>, Set<String>) -> SystemSnapshot = SystemSnapshot.capture) {
        self.manager = manager
        self.settings = settings
        self.pollInterval = pollInterval
        self.gracePeriod = gracePeriod
        self.snapshotProvider = snapshotProvider
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        lastSession = manager.session
        subscriptions = [
            // Settings publish before they change, so look once the change has landed.
            settings.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.ruleChanged() }
            },
            manager.$session.sink { [weak self] session in self?.sessionChanged(to: session) },
        ]
        ruleChanged()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        subscriptions = []
        changes.stop()
    }

    /// True while system change notifications are being watched (only while the rule is on).
    var isWatchingChanges: Bool { changes.isRunning }

    private var rule: CustomRule { settings.customRule }

    private var ruleSession: Session? {
        guard let session = manager.session, case .rule = session.trigger else { return nil }
        return session
    }

    // MARK: - Reacting to changes

    private func ruleChanged() {
        guard rule.isArmed else {
            timer?.invalidate()
            timer = nil
            changes.stop()
            isSuppressed = false
            unmetSince = nil
            if ruleSession != nil { changeSession { manager.end() } }
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.check() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        changes.start()
        check()
    }

    private func sessionChanged(to session: Session?) {
        defer { lastSession = session }
        guard !isChangingSession, let previous = lastSession, case .rule = previous.trigger,
              session !== previous else { return }
        // A rule session went away (or was replaced) without this class doing it: the user did.
        isSuppressed = true
        unmetSince = nil
    }

    // MARK: - Checking

    /// Checks the rule now (it's also checked every `pollInterval` seconds).
    func check() {
        guard rule.isArmed else { return }
        guard !isChecking else {
            needsAnotherCheck = true
            return
        }
        isChecking = true
        let kinds = rule.watchedKinds
        let apps = kinds.contains(.appRunning) ? SystemSnapshot.runningBundleIDs() : []
        let provider = snapshotProvider
        queue.async { [weak self] in
            let snapshot = provider(kinds, apps)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isChecking = false
                apply(snapshot)
                if needsAnotherCheck {
                    needsAnotherCheck = false
                    check()
                }
            }
        }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        let rule = rule
        guard rule.isArmed else { return }
        let armed = rule.armedRule

        if rule.isMet(in: snapshot) {
            unmetSince = nil
            if let session = ruleSession {
                // The rule was edited while its session runs: keep going, with the new description.
                if case .rule(let running) = session.trigger, running != armed {
                    changeSession { manager.start(.rule(armed)) }
                }
            } else if manager.session == nil, !isSuppressed {
                changeSession { manager.start(.rule(armed)) }
            }
            return
        }

        isSuppressed = false
        guard ruleSession != nil else {
            unmetSince = nil
            return
        }
        let unmet = armed.conditions.filter { !$0.isMet(in: snapshot) }
        let grace = gracePeriod ?? unmet.map(\.kind.gracePeriod).max() ?? 0
        let now = Date()
        let since = unmetSince ?? now
        unmetSince = since
        let remaining = grace - now.timeIntervalSince(since)
        guard remaining <= 0 else {
            // Look again the moment the grace period runs out rather than at the next poll.
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.05) { [weak self] in self?.check() }
            return
        }
        unmetSince = nil
        changeSession {
            manager.end(reason: unmet.first.map { "No longer true: \($0.phrase)." } ?? "The rule is no longer met.")
        }
    }

    private func changeSession(_ change: () -> Void) {
        isChangingSession = true
        change()
        isChangingSession = false
    }
}
