import XCTest
@testable import Wakeful

final class UpdateCheckerTests: XCTestCase {
    func testParsesPlainVersions() {
        XCTAssertEqual(UpdateChecker.parseVersion("1.2.3"), [1, 2, 3])
        XCTAssertEqual(UpdateChecker.parseVersion("v1.2.3"), [1, 2, 3])
        XCTAssertEqual(UpdateChecker.parseVersion("2"), [2])
        XCTAssertEqual(UpdateChecker.parseVersion("v10.0.0.1"), [10, 0, 0, 1])
        XCTAssertEqual(UpdateChecker.parseVersion("01.002"), [1, 2])
    }

    /// The tag comes from the network, so anything that isn't digits and dots must be rejected.
    func testRejectsHostileTags() {
        let hostile = [
            "", "v", "vv1.0", "V1.0", "1..2", ".1", "1.", "1.2.3.4.5", "-1.0", "+1.0", "1.0-beta",
            "1.0 ", " 1.0", "1.0\n", "1.0\0", "1.2.3/../../evil", "1.2.3?x=1", "1.2.3#x", "1.2.3%2F",
            "1.2.3@evil.com", "https://evil.com", "１.２.３", "١.٢", "1e3", "0x10", "1234567.0",
            String(repeating: "9", count: 100), String(repeating: "1.", count: 1000) + "1",
        ]
        for tag in hostile {
            XCTAssertNil(UpdateChecker.parseVersion(tag), tag.debugDescription)
            XCTAssertNil(UpdateChecker.releasePage(for: tag), tag.debugDescription)
            XCTAssertEqual(UpdateChecker.outcome(latestTag: tag, currentVersion: "1.0"),
                           .failed("The latest release has an unrecognized version."), tag.debugDescription)
        }
    }

    func testComparesVersions() {
        XCTAssertTrue(UpdateChecker.isNewer([1, 1, 3], than: [1, 1, 2]))
        XCTAssertTrue(UpdateChecker.isNewer([1, 10], than: [1, 9]))
        XCTAssertTrue(UpdateChecker.isNewer([2], than: [1, 99, 99]))
        XCTAssertTrue(UpdateChecker.isNewer([1, 0, 0, 1], than: [1]))
        XCTAssertFalse(UpdateChecker.isNewer([1, 1, 2], than: [1, 1, 2]))
        XCTAssertFalse(UpdateChecker.isNewer([1, 0], than: [1, 0, 0]))
        XCTAssertFalse(UpdateChecker.isNewer([1, 1, 1], than: [1, 1, 2]))
    }

    func testOutcome() {
        XCTAssertEqual(UpdateChecker.outcome(latestTag: "v1.2.0", currentVersion: "1.1.2"), .available(version: "1.2.0"))
        XCTAssertEqual(UpdateChecker.outcome(latestTag: "v01.02", currentVersion: "1.1.2"), .available(version: "1.2"))
        XCTAssertEqual(UpdateChecker.outcome(latestTag: "v1.1.2", currentVersion: "1.1.2"), .upToDate)
        XCTAssertEqual(UpdateChecker.outcome(latestTag: "v1.0.0", currentVersion: "1.1.2"), .upToDate)
        // A copy without a readable version (e.g. `swift run`) treats any release as newer.
        XCTAssertEqual(UpdateChecker.outcome(latestTag: "v1.0", currentVersion: "dev"), .available(version: "1.0"))
    }

    func testReleasePageIsFixedPrefixPlusVersion() {
        XCTAssertEqual(UpdateChecker.releasePage(for: "1.2.0")?.absoluteString,
                       "https://github.com/aminealichaouche/wakeful/releases/tag/v1.2.0")
        let page = UpdateChecker.releasePage(for: "v3.4")
        XCTAssertEqual(page?.scheme, "https")
        XCTAssertEqual(page?.host, "github.com")
        XCTAssertEqual(page?.path, "/aminealichaouche/wakeful/releases/tag/v3.4")
    }

    func testAPIAddressIsGitHubOverHTTPS() {
        XCTAssertEqual(UpdateChecker.latestReleaseAPI.scheme, "https")
        XCTAssertEqual(UpdateChecker.latestReleaseAPI.host, "api.github.com")
        XCTAssertEqual(UpdateChecker.latestReleaseAPI.path, "/repos/aminealichaouche/wakeful/releases/latest")
    }

    func testAutomaticChecksAreOffByDefault() {
        let (settings, cleanup) = makeTestSettings()
        defer { cleanup() }
        XCTAssertFalse(settings.checkForUpdatesAutomatically)
    }
}

/// Talks to the real GitHub API. Opt in with WAKEFUL_NETWORK_TESTS=1.
final class UpdateCheckerNetworkTests: XCTestCase {
    func testFetchesLatestReleaseOrReportsNone() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAKEFUL_NETWORK_TESTS"] == "1",
                          "set WAKEFUL_NETWORK_TESTS=1 to run")
        do {
            let tag = try await UpdateChecker.fetchLatestTag()
            XCTAssertNotNil(UpdateChecker.parseVersion(tag), tag)
        } catch let error as UpdateChecker.UpdateError {
            XCTAssertEqual(error.message, "No release has been published yet.")
        }
    }
}
