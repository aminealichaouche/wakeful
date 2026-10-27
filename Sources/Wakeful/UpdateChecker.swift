#if !OFFLINE
// The offline edition is built with -DOFFLINE and contains none of this: it never connects
// to the internet.

import AppKit

/// Looks for a newer Wakeful release on GitHub.
///
/// Kept deliberately small so there's little to attack:
/// - The only request is an HTTPS GET to one fixed GitHub API address. No cookies, cache or
///   credentials are used, redirects are refused, and the reply is capped at 1 MB.
/// - Nothing is downloaded or installed. The reply only contributes a version number, which must be
///   plain digits and dots; the update button opens a page built from a fixed address plus that number.
/// - Automatic checks are off unless turned on in Settings.
final class UpdateChecker: ObservableObject {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/aminealichaouche/wakeful/releases/latest")!
    static let releasePagePrefix = "https://github.com/aminealichaouche/wakeful/releases/tag/v"
    static let maxResponseBytes = 1 << 20
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    /// A manual check shows "Checking…" at least this long, so a fast reply doesn't just flicker.
    static let minimumCheckingTime: TimeInterval = 0.8
    static let upToDateDisplayTime: TimeInterval = 3
    static let failureDisplayTime: TimeInterval = 5

    enum Outcome: Equatable {
        case upToDate
        case available(version: String)
        case failed(String)
    }

    /// What the update button shows.
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        /// A newer release, as plain "1.2.3".
        case available(version: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    let currentVersion: String
    private var timer: Timer?
    private var notifiedVersion: String?
    private var isFetching = false
    /// Set by a manual check; automatic checks only surface a new version.
    private var reportsResult = false
    private var checkStarted = Date.distantPast
    private var resetToIdle: DispatchWorkItem?

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.currentVersion = currentVersion
    }

    /// Checks now and shows the result on the update button.
    func checkNow() {
        guard status != .checking else { return }
        resetToIdle?.cancel()
        reportsResult = true
        checkStarted = Date()
        status = .checking
        fetch()
    }

    /// Opens the GitHub page of the version found by the last check.
    func openReleasePage() {
        guard case .available(let version) = status, let page = Self.releasePage(for: version) else { return }
        NSWorkspace.shared.open(page)
    }

    /// Checks once now and then daily while Wakeful runs, notifying about each new version once.
    func setAutomaticChecks(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        fetch()
        let timer = Timer(timeInterval: Self.automaticCheckInterval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fetch() {
        guard !isFetching else { return }
        isFetching = true
        let currentVersion = currentVersion
        Task {
            let outcome: Outcome
            do {
                outcome = Self.outcome(latestTag: try await Self.fetchLatestTag(), currentVersion: currentVersion)
            } catch let error as UpdateError {
                outcome = .failed(error.message)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await MainActor.run { self.finish(outcome) }
        }
    }

    private func finish(_ outcome: Outcome) {
        isFetching = false
        guard reportsResult else {
            if case .available(let version) = outcome {
                status = .available(version: version)
                notifyIfNew(version)
            }
            return
        }
        let delay = max(0, Self.minimumCheckingTime - Date().timeIntervalSince(checkStarted))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reportsResult = false
            switch outcome {
            case .available(let version):
                self.status = .available(version: version)
            case .upToDate:
                self.show(.upToDate, for: Self.upToDateDisplayTime)
            case .failed(let reason):
                self.show(.failed(reason), for: Self.failureDisplayTime)
            }
        }
    }

    /// Shows a temporary result, then returns the button to "Check for Updates".
    private func show(_ result: Status, for duration: TimeInterval) {
        status = result
        let reset = DispatchWorkItem { [weak self] in
            if self?.status == result { self?.status = .idle }
        }
        resetToIdle = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: reset)
    }

    private func notifyIfNew(_ version: String) {
        guard version != notifiedVersion else { return }
        notifiedVersion = version
        Notifier.post(title: "Wakeful \(version) Is Available", body: "Open Wakeful's menu and click the update button.")
    }

    // MARK: - Request

    struct UpdateError: Error {
        let message: String
    }

    private struct Release: Decodable {
        let tag_name: String
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// Refuses every redirect, so the reply can only come from the fixed API address.
    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func fetchLatestTag() async throws -> String {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Wakeful", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request, delegate: RefuseRedirects())
        guard let http = response as? HTTPURLResponse, http.url == latestReleaseAPI else {
            throw UpdateError(message: "GitHub sent an unexpected response.")
        }
        switch http.statusCode {
        case 200: break
        case 404: throw UpdateError(message: "No release has been published yet.")
        case 403, 429: throw UpdateError(message: "GitHub is limiting requests right now. Try again later.")
        default: throw UpdateError(message: "GitHub returned an error (\(http.statusCode)).")
        }

        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponseBytes {
                throw UpdateError(message: "GitHub's reply was too large.")
            }
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw UpdateError(message: "GitHub's reply couldn't be read.")
        }
        return release.tag_name
    }

    // MARK: - Versions

    static func outcome(latestTag: String, currentVersion: String) -> Outcome {
        guard let latest = parseVersion(latestTag) else {
            return .failed("The latest release has an unrecognized version.")
        }
        guard isNewer(latest, than: parseVersion(currentVersion) ?? [0]) else { return .upToDate }
        return .available(version: latest.map(String.init).joined(separator: "."))
    }

    /// "v1.2.3" or "1.2.3" → [1, 2, 3]. Anything else (other characters, empty parts, more than
    /// four parts, numbers over six digits) is rejected.
    static func parseVersion(_ text: String) -> [Int]? {
        let digits = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...6).contains(part.count), part.allSatisfy({ ("0"..."9").contains($0) }),
                  let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    static func isNewer(_ version: [Int], than other: [Int]) -> Bool {
        let count = max(version.count, other.count)
        let padded = { (parts: [Int]) in parts + Array(repeating: 0, count: count - parts.count) }
        return padded(other).lexicographicallyPrecedes(padded(version))
    }

    /// The GitHub page for a release, or nil unless `version` is plain digits and dots.
    static func releasePage(for version: String) -> URL? {
        guard let parts = parseVersion(version) else { return nil }
        return URL(string: releasePagePrefix + parts.map(String.init).joined(separator: "."))
    }
}

#endif
