import AppKit

/// A drive or network share picked in a rule.
struct DriveChoice: Codable, Hashable {
    var id: String
    var name: String
}

/// An app picked in a rule.
struct AppChoice: Codable, Hashable {
    var bundleID: String
    var name: String
}

/// One thing a custom rule can wait for.
enum RuleCondition: Codable, Hashable {
    /// A specific external drive, or any (nil). Disk images and network shares never count.
    case externalDrive(DriveChoice?)
    /// A specific network share, or any (nil).
    case networkDrive(DriveChoice?)
    case charger
    case externalDisplay
    case audioPlaying
    case appRunning(AppChoice)

    /// The kinds offered by "Add Condition", in menu order.
    enum Kind: CaseIterable {
        case externalDrive, networkDrive, charger, externalDisplay, audioPlaying, appRunning

        var title: String {
            switch self {
            case .externalDrive: return "External Drive Is Connected"
            case .networkDrive: return "Network Drive Is Attached"
            case .charger: return "Charger Is Connected"
            case .externalDisplay: return "External Display Is Connected"
            case .audioPlaying: return "Audio Is Playing"
            case .appRunning: return "App Is Running"
            }
        }

        var icon: String {
            switch self {
            case .externalDrive: return "externaldrive"
            case .networkDrive: return "externaldrive.connected.to.line.below"
            case .charger: return "powerplug"
            case .externalDisplay: return "display.2"
            case .audioPlaying: return "speaker.wave.2"
            case .appRunning: return "app"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .externalDrive: return .externalDrive
        case .networkDrive: return .networkDrive
        case .charger: return .charger
        case .externalDisplay: return .externalDisplay
        case .audioPlaying: return .audioPlaying
        case .appRunning: return .appRunning
        }
    }

    func isMet(in snapshot: SystemSnapshot) -> Bool {
        switch self {
        case .externalDrive(let drive):
            return snapshot.volumes.contains { $0.kind == .external && (drive == nil || $0.id == drive?.id) }
        case .networkDrive(let share):
            return snapshot.volumes.contains { $0.kind == .network && (share == nil || $0.id == share?.id) }
        case .charger:
            return snapshot.onACPower
        case .externalDisplay:
            return snapshot.externalDisplayConnected
        case .audioPlaying:
            return snapshot.audioPlaying
        case .appRunning(let app):
            return snapshot.runningBundleIDs.contains(app.bundleID)
        }
    }

    /// Reads as part of "While … and …".
    var phrase: String {
        switch self {
        case .externalDrive(nil): return "an external drive is connected"
        case .externalDrive(let drive?): return "“\(drive.name)” is connected"
        case .networkDrive(nil): return "a network drive is attached"
        case .networkDrive(let share?): return "“\(share.name)” is attached"
        case .charger: return "the charger is connected"
        case .externalDisplay: return "an external display is connected"
        case .audioPlaying: return "audio is playing"
        case .appRunning(let app): return "“\(app.name)” is running"
        }
    }
}

/// "Keep the Mac awake while all (or any) of the turned-on conditions are true."
///
/// Each condition has its own on/off switch and starts off. While at least one is on, Wakeful
/// watches the rule and runs a session whenever it's met (see `RuleAutomation`).
struct CustomRule: Equatable {
    enum Match: String, Codable, CaseIterable {
        case all, any
    }

    struct Item: Codable, Hashable {
        var condition: RuleCondition
        var isOn = false
    }

    static let maxConditions = 8

    var match: Match = .all
    var items: [Item] = []

    init(match: Match = .all, items: [Item] = []) {
        self.match = match
        self.items = items
    }

    /// A rule whose conditions are all turned on, as used for a running session.
    init(match: Match = .all, conditions: [RuleCondition]) {
        self.init(match: match, items: conditions.map { Item(condition: $0, isOn: true) })
    }

    /// The conditions that are switched on. Only these count.
    var conditions: [RuleCondition] {
        items.filter(\.isOn).map(\.condition)
    }

    /// True when at least one condition is switched on.
    var isArmed: Bool {
        items.contains(where: \.isOn)
    }

    /// Just the switched-on conditions, for the session that runs while they hold.
    var armedRule: CustomRule {
        CustomRule(match: match, conditions: conditions)
    }

    /// A rule with nothing switched on is never met.
    func isMet(in snapshot: SystemSnapshot) -> Bool {
        let conditions = conditions
        guard !conditions.isEmpty else { return false }
        switch match {
        case .all: return conditions.allSatisfy { $0.isMet(in: snapshot) }
        case .any: return conditions.contains { $0.isMet(in: snapshot) }
        }
    }

    /// "“T7” is connected and the charger is connected"
    var summary: String {
        let phrases = conditions.map(\.phrase)
        guard phrases.count > 1 else { return phrases.first ?? "" }
        let joiner = match == .all ? "and" : "or"
        return phrases.dropLast().joined(separator: ", ") + " \(joiner) " + phrases.last!
    }

    /// Which parts of the system the switched-on conditions look at, so a snapshot only gathers those.
    var watchedKinds: Set<RuleCondition.Kind> {
        Set(conditions.map(\.kind))
    }

    /// Decodes a stored rule, dropping anything unreadable instead of failing.
    static func decode(_ data: Data?) -> CustomRule {
        guard let data, let rule = try? JSONDecoder().decode(CustomRule.self, from: data) else { return CustomRule() }
        return CustomRule(match: rule.match, items: Array(rule.items.prefix(maxConditions)))
    }
}

extension CustomRule: Codable {
    private enum CodingKeys: String, CodingKey {
        case match, items
        /// Version 1.2.0 stored a plain list with no on/off switches.
        case conditions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = try container.decode(Match.self, forKey: .match)
        if let items = try container.decodeIfPresent([Item].self, forKey: .items) {
            self.items = items
        } else {
            // Rules saved by 1.2.0 come back with every condition switched off.
            items = try container.decode([RuleCondition].self, forKey: .conditions).map { Item(condition: $0) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(match, forKey: .match)
        try container.encode(items, forKey: .items)
    }
}

/// The state of everything rules can look at, gathered at one moment.
struct SystemSnapshot: Equatable {
    var volumes: [MountedVolume] = []
    var onACPower = false
    var externalDisplayConnected = false
    var audioPlaying = false
    var runningBundleIDs: Set<String> = []

    /// Bundle IDs of running apps. Reads AppKit state, so call it on the main thread.
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Gathers the parts in `kinds`. Safe to call off the main thread; apps are passed in.
    static func capture(_ kinds: Set<RuleCondition.Kind>, runningBundleIDs: Set<String>) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        if kinds.contains(.externalDrive) || kinds.contains(.networkDrive) {
            snapshot.volumes = Volumes.mounted()
        }
        if kinds.contains(.charger) {
            snapshot.onACPower = PowerSource.isOnACPower
        }
        if kinds.contains(.externalDisplay) {
            snapshot.externalDisplayConnected = Displays.isExternalDisplayConnected
        }
        if kinds.contains(.audioPlaying) {
            snapshot.audioPlaying = AudioOutput.isPlaying
        }
        snapshot.runningBundleIDs = runningBundleIDs
        return snapshot
    }
}
