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

/// "Keep the Mac awake while all (or any) of these are true."
struct CustomRule: Codable, Equatable {
    enum Match: String, Codable, CaseIterable {
        case all, any
    }

    static let maxConditions = 8

    var match: Match = .all
    var conditions: [RuleCondition] = []

    /// An empty rule is never met.
    func isMet(in snapshot: SystemSnapshot) -> Bool {
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

    /// Which parts of the system the rule looks at, so a snapshot only gathers those.
    var watchedKinds: Set<RuleCondition.Kind> {
        Set(conditions.map(\.kind))
    }

    /// Decodes a stored rule, dropping anything unreadable instead of failing.
    static func decode(_ data: Data?) -> CustomRule {
        guard let data, let rule = try? JSONDecoder().decode(CustomRule.self, from: data) else { return CustomRule() }
        return CustomRule(match: rule.match, conditions: Array(rule.conditions.prefix(maxConditions)))
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
