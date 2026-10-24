import XCTest
@testable import Wakeful

final class FormatTests: XCTestCase {
    func testKnownDurations() {
        XCTAssertEqual(Format.duration(0), "0s")
        XCTAssertEqual(Format.duration(1), "1s")
        XCTAssertEqual(Format.duration(0.2), "1s", "partial seconds round up")
        XCTAssertEqual(Format.duration(59.2), "1m 00s")
        XCTAssertEqual(Format.duration(61), "1m 01s")
        XCTAssertEqual(Format.duration(3600), "1h 00m 00s")
        XCTAssertEqual(Format.duration(3 * 3600 + 5 * 60 + 9), "3h 05m 09s")
        XCTAssertEqual(Format.duration(100 * 3600), "100h 00m 00s")
    }

    func testNegativeAndHugeValuesDoNotCrash() {
        XCTAssertEqual(Format.duration(-5), "0s")
        XCTAssertEqual(Format.duration(-.greatestFiniteMagnitude), "0s")
        XCTAssertFalse(Format.duration(Date.distantFuture.timeIntervalSinceNow).isEmpty)
        XCTAssertFalse(Format.duration(.greatestFiniteMagnitude).isEmpty)
        XCTAssertFalse(Format.duration(.infinity).isEmpty)
        XCTAssertEqual(Format.duration(.nan), "0s")
    }

    /// Formats 100k random durations and parses them back.
    func testFuzzRoundTrip() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<100_000 {
            let interval = Double.random(in: 0..<400_000, using: &generator)
            let text = Format.duration(interval)
            var total = 0
            for part in text.split(separator: " ") {
                let value = Int(part.dropLast())!
                switch part.last {
                case "h": total += value * 3600
                case "m": total += value * 60
                case "s": total += value
                default: XCTFail("unexpected unit in \(text)")
                }
            }
            XCTAssertEqual(total, Int(interval.rounded(.up)), text)
        }
    }
}

final class SessionDescriptionTests: XCTestCase {
    func testManualSessions() {
        let indefinite = Session(trigger: .manual(until: nil))
        XCTAssertNil(indefinite.endDate)
        XCTAssertEqual(indefinite.remainingDescription, "Indeterminate time remaining")
        XCTAssertEqual(indefinite.triggerDescription, "Manual Activation")

        let timed = Session(trigger: .manual(until: Date().addingTimeInterval(90)))
        XCTAssertTrue(timed.remainingDescription.hasSuffix("remaining"))
        XCTAssertTrue(timed.remainingDescription.hasPrefix("1m 3") || timed.remainingDescription.hasPrefix("1m 2"))
    }

    func testDownloadSessionUsesFileName() {
        let url = URL(fileURLWithPath: "/tmp/some \"weird\" name'; rm -rf ~.crdownload")
        let session = Session(trigger: .download(DownloadWatcher(url: url)))
        XCTAssertEqual(session.triggerDescription, "While “some \"weird\" name'; rm -rf ~.crdownload” is downloading")
        XCTAssertEqual(session.remainingDescription, "Indeterminate time remaining")
    }
}

final class SettingsTests: XCTestCase {
    func testDefaults() {
        let suite = "wakeful-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertFalse(settings.allowDisplaySleep)
        XCTAssertTrue(settings.allowSleepWhenDisplayClosed, "closed-lid mode must be opt-in")
        XCTAssertFalse(settings.allowScreenSaver)
        XCTAssertEqual(settings.screenSaverDelayMinutes, 45)
        XCTAssertFalse(settings.startSessionAtLaunch)
        XCTAssertTrue(settings.notifyWhenSessionEnds)
        XCTAssertEqual(settings.lowBatteryThreshold, 0)
    }

    func testValuesPersistAcrossInstances() {
        let suite = "wakeful-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = Settings(defaults: UserDefaults(suiteName: suite)!)
        first.allowDisplaySleep = true
        first.screenSaverDelayMinutes = 10
        first.lowBatteryThreshold = 20
        let second = Settings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(second.allowDisplaySleep)
        XCTAssertEqual(second.screenSaverDelayMinutes, 10)
        XCTAssertEqual(second.lowBatteryThreshold, 20)
    }

    func testAbsurdStoredValuesAreClamped() {
        let suite = "wakeful-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(-50, forKey: "screenSaverDelayMinutes")
        defaults.set(Int.max, forKey: "lowBatteryThreshold")
        let settings = Settings(defaults: defaults)
        XCTAssertGreaterThanOrEqual(settings.screenSaverDelayMinutes, 1)
        XCTAssertLessThanOrEqual(settings.lowBatteryThreshold, 100)

        defaults.set(Int.max, forKey: "screenSaverDelayMinutes")
        defaults.set(-1, forKey: "lowBatteryThreshold")
        XCTAssertLessThanOrEqual(settings.screenSaverDelayMinutes, 24 * 60)
        XCTAssertGreaterThanOrEqual(settings.lowBatteryThreshold, 0)
    }

    func testObserversAreNotifiedOnChange() {
        let (settings, cleanup) = makeTestSettings()
        defer { cleanup() }
        var notifications = 0
        let token = settings.objectWillChange.sink { notifications += 1 }
        settings.allowScreenSaver.toggle()
        settings.screenSaverDelayMinutes = 5
        XCTAssertEqual(notifications, 2)
        token.cancel()
    }
}

final class SystemInfoTests: XCTestCase {
    func testBatteryStatusIsSaneWhenPresent() {
        guard let status = Battery.status() else { return } // desktops have no battery
        XCTAssertTrue((0...100).contains(status.percent), "\(status.percent)")
    }

    func testIdleTimeIsNonNegative() {
        XCTAssertGreaterThanOrEqual(UserIdle.seconds, 0)
    }
}
