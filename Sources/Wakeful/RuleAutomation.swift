import AppKit
import Combine

/// Runs the custom rule. While any of its conditions is switched on, it checks the rule every few
/// seconds and keeps a session going whenever the rule is met:
///
/// - Rule met and nothing else running: starts a session.
/// - Rule no longer met for `gracePeriod`: ends that session, so a drive or share that drops for a
///   moment (a NAS reconnecting) doesn't end it.
/// - A session started by hand is never replaced or ended.
/// - If you end (or replace) a rule session yourself, it stays off until the rule next stops being
///   met, instead of starting again a moment later.
final class RuleAutomation {
    static let defaultPollInterval: TimeInterval = 2
    static let defaultGracePeriod: TimeInterval = 5

    private let manager: SessionManager
    private let settings: Settings
    private let pollInterval: TimeInterval
    let gracePeriod: TimeInterval
    private let snapshotProvider: (Set<RuleCondition.Kind>, Set<String>) -> SystemSnapshot
    /// Rule checks list mounted volumes and query audio devices, so they run off the main thread.
    private let queue = DispatchQueue(label: "io.github.wakeful.rule-automation")

    private var timer: Timer?
    private var subscriptions: [AnyCancellable] = []
    private var isChecking = false
    private var unmetSince: Date?
    /// Set when the user ends or replaces a rule session; cleared once the rule stops being met.
    private(set) var isSuppressed = false
    /// True while this class itself starts or ends a session, so it isn't mistaken for the user.
    private var isChangingSession = false
    private var lastSession: Session?

    init(manager: SessionManager, settings: Settings,
         pollInterval: TimeInterval = RuleAutomation.defaultPollInterval,
         gracePeriod: TimeInterval = RuleAutomation.defaultGracePeriod,
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
    }

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
        guard rule.isArmed, !isChecking else { return }
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
        let now = Date()
        let since = unmetSince ?? now
        unmetSince = since
        guard now.timeIntervalSince(since) >= gracePeriod else { return }
        unmetSince = nil
        let unmet = armed.conditions.first { !$0.isMet(in: snapshot) }
        changeSession {
            manager.end(reason: unmet.map { "No longer true: \($0.phrase)." } ?? "The rule is no longer met.")
        }
    }

    private func changeSession(_ change: () -> Void) {
        isChangingSession = true
        change()
        isChangingSession = false
    }
}
