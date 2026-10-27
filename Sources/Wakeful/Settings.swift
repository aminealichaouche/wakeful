import Combine
import Foundation

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    private enum Key {
        static let allowDisplaySleep = "allowDisplaySleep"
        static let allowSleepWhenDisplayClosed = "allowSleepWhenDisplayClosed"
        static let allowScreenSaver = "allowScreenSaver"
        static let screenSaverDelayMinutes = "screenSaverDelayMinutes"
        static let startSessionAtLaunch = "startSessionAtLaunch"
        static let notifyWhenSessionEnds = "notifyWhenSessionEnds"
        static let lowBatteryThreshold = "lowBatteryThreshold"
        static let checkForUpdatesAutomatically = "checkForUpdatesAutomatically"
        static let customRule = "customRule"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.allowDisplaySleep: false,
            Key.allowSleepWhenDisplayClosed: true,
            Key.allowScreenSaver: false,
            Key.screenSaverDelayMinutes: 45,
            Key.startSessionAtLaunch: false,
            Key.notifyWhenSessionEnds: true,
            Key.lowBatteryThreshold: 0,
        ])
        #if !OFFLINE
        defaults.register(defaults: [Key.checkForUpdatesAutomatically: false])
        #endif
    }

    /// When true, only system sleep is prevented; the display may still turn off.
    var allowDisplaySleep: Bool {
        get { defaults.bool(forKey: Key.allowDisplaySleep) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.allowDisplaySleep) }
    }

    /// When false, closed-display mode is enabled (requires an admin password).
    var allowSleepWhenDisplayClosed: Bool {
        get { defaults.bool(forKey: Key.allowSleepWhenDisplayClosed) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.allowSleepWhenDisplayClosed) }
    }

    var allowScreenSaver: Bool {
        get { defaults.bool(forKey: Key.allowScreenSaver) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.allowScreenSaver) }
    }

    var screenSaverDelayMinutes: Int {
        get { min(max(defaults.integer(forKey: Key.screenSaverDelayMinutes), 1), 24 * 60) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.screenSaverDelayMinutes) }
    }

    var startSessionAtLaunch: Bool {
        get { defaults.bool(forKey: Key.startSessionAtLaunch) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.startSessionAtLaunch) }
    }

    var notifyWhenSessionEnds: Bool {
        get { defaults.bool(forKey: Key.notifyWhenSessionEnds) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.notifyWhenSessionEnds) }
    }

    /// Battery percentage at which a session is ended automatically. 0 disables the check.
    var lowBatteryThreshold: Int {
        get { min(max(defaults.integer(forKey: Key.lowBatteryThreshold), 0), 100) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.lowBatteryThreshold) }
    }

    /// The rule last set up under "While Custom Rule…", kept for next time.
    var customRule: CustomRule {
        get {
            // The rule page reads this many times per redraw, so only decode when the stored data changes.
            let data = defaults.data(forKey: Key.customRule)
            if let cached = cachedRule, cached.data == data { return cached.rule }
            let rule = CustomRule.decode(data)
            cachedRule = (data, rule)
            return rule
        }
        set {
            objectWillChange.send()
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.customRule)
            cachedRule = (data, newValue)
        }
    }
    private var cachedRule: (data: Data?, rule: CustomRule)?

    #if !OFFLINE
    /// Off by default: Wakeful makes no network requests unless asked to.
    var checkForUpdatesAutomatically: Bool {
        get { defaults.bool(forKey: Key.checkForUpdatesAutomatically) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.checkForUpdatesAutomatically) }
    }
    #endif
}
