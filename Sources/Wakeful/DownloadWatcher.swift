import Foundation

/// Tracks an in-progress download (e.g. `.crdownload`, `.part`, Safari `.download` bundles).
///
/// Browsers rename or remove the partial file once the download completes, so the download is
/// considered finished when the file disappears. If it stops growing for `stallTimeout`, it is
/// considered stalled so a paused download can't keep the Mac awake forever.
final class DownloadWatcher {
    enum State {
        case downloading
        case finished
        case stalled
    }

    let url: URL
    private let stallTimeout: TimeInterval
    private var lastSize: UInt64
    private var lastChange = Date()

    init(url: URL, stallTimeout: TimeInterval = 10 * 60) {
        self.url = url
        self.stallTimeout = stallTimeout
        lastSize = Self.size(of: url) ?? 0
    }

    func poll() -> State {
        guard let size = Self.size(of: url) else { return .finished }
        if size != lastSize {
            lastSize = size
            lastChange = Date()
        }
        return Date().timeIntervalSince(lastChange) > stallTimeout ? .stalled : .downloading
    }

    private static func size(of url: URL) -> UInt64? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        guard isDirectory.boolValue else {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        }
        var total: UInt64 = 0
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let file = enumerator?.nextObject() as? URL {
            total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
