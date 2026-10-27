import AppKit
import XCTest
@testable import Wakeful

final class CustomRuleTests: XCTestCase {
    private let t7 = MountedVolume(kind: .external, id: "UUID-T7", name: "T7", mountPoint: "/Volumes/T7")
    private let nas = MountedVolume(kind: .network, id: "192.168.50.197/Everything", name: "Everything",
                                    mountPoint: "/Volumes/Everything")
    private let dmg = MountedVolume(kind: .diskImage, id: "UUID-DMG", name: "Installer", mountPoint: "/Volumes/Installer")

    // MARK: - Conditions

    func testExternalDriveConditions() {
        let anyDrive = RuleCondition.externalDrive(nil)
        let specific = RuleCondition.externalDrive(DriveChoice(id: "UUID-T7", name: "T7"))
        let other = RuleCondition.externalDrive(DriveChoice(id: "UUID-OTHER", name: "Backup"))

        XCTAssertFalse(anyDrive.isMet(in: SystemSnapshot()))
        XCTAssertFalse(anyDrive.isMet(in: SystemSnapshot(volumes: [dmg])), "disk images don't count")
        XCTAssertFalse(anyDrive.isMet(in: SystemSnapshot(volumes: [nas])), "network shares don't count")
        XCTAssertTrue(anyDrive.isMet(in: SystemSnapshot(volumes: [dmg, nas, t7])))
        XCTAssertTrue(specific.isMet(in: SystemSnapshot(volumes: [t7])))
        XCTAssertFalse(other.isMet(in: SystemSnapshot(volumes: [t7])))
        // Matched by identity, not name: another drive that happens to be called "T7".
        let impostor = MountedVolume(kind: .external, id: "UUID-X", name: "T7", mountPoint: "/Volumes/T7 1")
        XCTAssertFalse(specific.isMet(in: SystemSnapshot(volumes: [impostor])))
        // A disk image with the same UUID as the chosen drive still isn't the drive.
        let dmgCopy = MountedVolume(kind: .diskImage, id: "UUID-T7", name: "T7", mountPoint: "/Volumes/T7")
        XCTAssertFalse(specific.isMet(in: SystemSnapshot(volumes: [dmgCopy])))
    }

    func testNetworkDriveConditions() {
        let anyShare = RuleCondition.networkDrive(nil)
        let specific = RuleCondition.networkDrive(DriveChoice(id: "192.168.50.197/Everything", name: "Everything"))
        XCTAssertFalse(anyShare.isMet(in: SystemSnapshot(volumes: [t7, dmg])), "local drives don't count")
        XCTAssertTrue(anyShare.isMet(in: SystemSnapshot(volumes: [nas])))
        XCTAssertTrue(specific.isMet(in: SystemSnapshot(volumes: [t7, nas])))
        XCTAssertFalse(specific.isMet(in: SystemSnapshot(volumes: [
            MountedVolume(kind: .network, id: "10.0.0.2/Everything", name: "Everything", mountPoint: "/Volumes/Everything"),
        ])), "same share name on a different server")
    }

    func testOtherConditions() {
        XCTAssertTrue(RuleCondition.charger.isMet(in: SystemSnapshot(onACPower: true)))
        XCTAssertFalse(RuleCondition.charger.isMet(in: SystemSnapshot(onACPower: false)))
        XCTAssertTrue(RuleCondition.externalDisplay.isMet(in: SystemSnapshot(externalDisplayConnected: true)))
        XCTAssertFalse(RuleCondition.externalDisplay.isMet(in: SystemSnapshot()))
        XCTAssertTrue(RuleCondition.audioPlaying.isMet(in: SystemSnapshot(audioPlaying: true)))
        XCTAssertFalse(RuleCondition.audioPlaying.isMet(in: SystemSnapshot()))
        let xcode = RuleCondition.appRunning(AppChoice(bundleID: "com.apple.dt.Xcode", name: "Xcode"))
        XCTAssertTrue(xcode.isMet(in: SystemSnapshot(runningBundleIDs: ["com.apple.dt.Xcode"])))
        XCTAssertFalse(xcode.isMet(in: SystemSnapshot(runningBundleIDs: ["com.apple.Safari"])))
    }

    // MARK: - All / any

    func testAllAndAny() {
        var rule = CustomRule(match: .all, conditions: [.externalDrive(nil), .charger])
        XCTAssertTrue(rule.isMet(in: SystemSnapshot(volumes: [t7], onACPower: true)))
        XCTAssertFalse(rule.isMet(in: SystemSnapshot(volumes: [t7], onACPower: false)))
        XCTAssertFalse(rule.isMet(in: SystemSnapshot(volumes: [], onACPower: true)))
        rule.match = .any
        XCTAssertTrue(rule.isMet(in: SystemSnapshot(volumes: [t7], onACPower: false)))
        XCTAssertTrue(rule.isMet(in: SystemSnapshot(volumes: [], onACPower: true)))
        XCTAssertFalse(rule.isMet(in: SystemSnapshot(volumes: [dmg], onACPower: false)))
    }

    func testSwitchedOffConditionsDontCount() {
        let snapshot = SystemSnapshot(volumes: [t7], onACPower: false)
        var rule = CustomRule(match: .all, items: [
            CustomRule.Item(condition: .externalDrive(nil), isOn: true),
            CustomRule.Item(condition: .charger, isOn: false),
        ])
        XCTAssertTrue(rule.isArmed)
        XCTAssertTrue(rule.isMet(in: snapshot), "the unmet charger condition is off")
        XCTAssertEqual(rule.conditions, [.externalDrive(nil)])
        XCTAssertEqual(rule.summary, "an external drive is connected")
        XCTAssertEqual(rule.watchedKinds, [.externalDrive])
        XCTAssertEqual(rule.armedRule, CustomRule(match: .all, conditions: [.externalDrive(nil)]))

        rule.items[0].isOn = false
        XCTAssertFalse(rule.isArmed)
        XCTAssertFalse(rule.isMet(in: snapshot), "nothing switched on")
        XCTAssertEqual(rule.watchedKinds, [])
    }

    func testNewConditionsStartOff() {
        XCTAssertFalse(CustomRule.Item(condition: .charger).isOn)
    }

    /// 1.2.0 saved a plain condition list; it loads with everything switched off.
    func testRulesSavedBy120LoadSwitchedOff() {
        let saved = Data(#"{"match":"any","conditions":[{"charger":{}},{"externalDrive":{"_0":{"id":"UUID-T7","name":"T7"}}}]}"#.utf8)
        let rule = CustomRule.decode(saved)
        XCTAssertEqual(rule.match, .any)
        XCTAssertEqual(rule.items.map(\.condition), [.charger, .externalDrive(DriveChoice(id: "UUID-T7", name: "T7"))])
        XCTAssertEqual(rule.items.map(\.isOn), [false, false])
        XCTAssertFalse(rule.isArmed)
    }

    func testEmptyRuleIsNeverMet() {
        let everything = SystemSnapshot(volumes: [t7, nas], onACPower: true, externalDisplayConnected: true,
                                        audioPlaying: true, runningBundleIDs: ["a"])
        XCTAssertFalse(CustomRule(match: .all, conditions: []).isMet(in: everything))
        XCTAssertFalse(CustomRule(match: .any, conditions: []).isMet(in: everything))
    }

    /// 20,000 random rules and system states, checked against a straightforward re-implementation.
    func testFuzzAgainstReference() {
        var generator = SystemRandomNumberGenerator()
        let pool: [RuleCondition] = [
            .externalDrive(nil), .externalDrive(DriveChoice(id: "UUID-T7", name: "T7")),
            .networkDrive(nil), .networkDrive(DriveChoice(id: "192.168.50.197/Everything", name: "Everything")),
            .charger, .externalDisplay, .audioPlaying, .appRunning(AppChoice(bundleID: "app.a", name: "A")),
        ]
        for _ in 0..<20_000 {
            let conditions = (0..<Int.random(in: 0...5, using: &generator)).map { _ in pool.randomElement(using: &generator)! }
            let rule = CustomRule(match: Bool.random(using: &generator) ? .all : .any, conditions: conditions)
            let snapshot = SystemSnapshot(
                volumes: [t7, nas, dmg].filter { _ in Bool.random(using: &generator) },
                onACPower: .random(using: &generator), externalDisplayConnected: .random(using: &generator),
                audioPlaying: .random(using: &generator),
                runningBundleIDs: Bool.random(using: &generator) ? ["app.a"] : [])

            func reference(_ condition: RuleCondition) -> Bool {
                let hasT7 = snapshot.volumes.contains(t7), hasNAS = snapshot.volumes.contains(nas)
                switch condition {
                case .externalDrive: return hasT7
                case .networkDrive: return hasNAS
                case .charger: return snapshot.onACPower
                case .externalDisplay: return snapshot.externalDisplayConnected
                case .audioPlaying: return snapshot.audioPlaying
                case .appRunning: return snapshot.runningBundleIDs.contains("app.a")
                }
            }
            let expected = !conditions.isEmpty
                && (rule.match == .all ? conditions.allSatisfy(reference) : conditions.contains(where: reference))
            XCTAssertEqual(rule.isMet(in: snapshot), expected, "\(rule) \(snapshot)")
        }
    }

    // MARK: - Wording

    func testSummaries() {
        XCTAssertEqual(CustomRule(conditions: [.externalDrive(nil)]).summary, "an external drive is connected")
        XCTAssertEqual(CustomRule(match: .all, conditions: [.externalDrive(DriveChoice(id: "x", name: "T7")), .charger]).summary,
                       "“T7” is connected and the charger is connected")
        XCTAssertEqual(CustomRule(match: .any, conditions: [.networkDrive(nil), .audioPlaying, .externalDisplay]).summary,
                       "a network drive is attached, audio is playing or an external display is connected")
        let session = Session(trigger: .rule(CustomRule(conditions: [.charger])))
        XCTAssertEqual(session.triggerDescription, "While the charger is connected")
        XCTAssertEqual(session.remainingDescription, "Active")
        XCTAssertNil(session.endDate)
    }

    func testEveryKindHasTitleAndIcon() {
        for kind in RuleCondition.Kind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertNotNil(NSImage(systemSymbolName: kind.icon, accessibilityDescription: nil), "missing symbol \(kind.icon)")
        }
        XCTAssertEqual(RuleCondition.Kind.allCases.count, 6)
    }

    // MARK: - Saving

    func testRuleRoundTripsThroughSettings() {
        let (settings, cleanup) = makeTestSettings()
        defer { cleanup() }
        XCTAssertEqual(settings.customRule, CustomRule(), "starts empty")
        let rule = CustomRule(match: .any, conditions: [
            .externalDrive(nil), .externalDrive(DriveChoice(id: "UUID-T7", name: "T7 “quoted”")),
            .networkDrive(DriveChoice(id: "nas.local/My Share", name: "My Share")), .charger,
            .externalDisplay, .audioPlaying, .appRunning(AppChoice(bundleID: "com.apple.Music", name: "Music")),
        ])
        settings.customRule = rule
        XCTAssertEqual(settings.customRule, rule)
    }

    func testCorruptOrHostileStoredRulesAreIgnored() throws {
        XCTAssertEqual(CustomRule.decode(nil), CustomRule())
        XCTAssertEqual(CustomRule.decode(Data("not json".utf8)), CustomRule())
        XCTAssertEqual(CustomRule.decode(Data(#"{"match":"sometimes","conditions":[]}"#.utf8)), CustomRule())
        XCTAssertEqual(CustomRule.decode(Data(#"{"match":"all","conditions":[{"selfDestruct":{}}]}"#.utf8)), CustomRule(),
                       "unknown condition from a newer version")
        // Huge stored rules are cut down to the maximum.
        let many = CustomRule(match: .all, conditions: Array(repeating: .charger, count: 500))
        let decoded = CustomRule.decode(try JSONEncoder().encode(many))
        XCTAssertEqual(decoded.items.count, CustomRule.maxConditions)
    }
}

/// The rule page's monitor, against the real system.
final class RuleMonitorTests: XCTestCase {
    func testRefreshFillsInSystemState() {
        let monitor = RuleMonitor()
        monitor.refresh()
        XCTAssertTrue(waitUntil(timeout: 5) { !monitor.snapshot.runningBundleIDs.isEmpty })
        XCTAssertEqual(monitor.snapshot.onACPower, PowerSource.isOnACPower)
        XCTAssertFalse(monitor.apps.contains { $0.bundleID == Bundle.main.bundleIdentifier }, "lists other apps only")
    }

    func testRefreshesWhileActiveOnly() {
        let lock = NSLock()
        var count = 0
        var captures: Int { lock.withLock { count } }
        let monitor = RuleMonitor { _, _ in
            let n = lock.withLock { count += 1; return count }
            return SystemSnapshot(onACPower: n % 2 == 0)
        }
        monitor.setActive(true)
        waitUntil(timeout: RuleMonitor.refreshInterval * 2 + 0.5) { false }
        XCTAssertGreaterThanOrEqual(captures, 2)
        monitor.setActive(false)
        waitUntil(timeout: 0.5) { false }  // let an in-flight capture finish
        let stopped = captures
        waitUntil(timeout: RuleMonitor.refreshInterval + 0.5) { false }
        XCTAssertEqual(captures, stopped, "kept polling after the page closed")
    }
}
