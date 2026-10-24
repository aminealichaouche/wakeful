import XCTest
@testable import Wakeful

final class DownloadWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = makeTempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testGrowingFileKeepsDownloading() throws {
        let file = dir.appendingPathComponent("a.crdownload")
        try Data(count: 1).write(to: file)
        let watcher = DownloadWatcher(url: file, stallTimeout: 0.5)
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0..<10 {
            handle.seekToEndOfFile()
            handle.write(Data(count: 4096))
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertEqual(watcher.poll(), .downloading)
        }
        try handle.close()
    }

    func testMissingFileIsFinished() {
        let watcher = DownloadWatcher(url: dir.appendingPathComponent("never-existed.part"))
        XCTAssertEqual(watcher.poll(), .finished)
    }

    func testDeletedFileIsFinished() throws {
        let file = dir.appendingPathComponent("b.part")
        try Data(count: 10).write(to: file)
        let watcher = DownloadWatcher(url: file)
        XCTAssertEqual(watcher.poll(), .downloading)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(watcher.poll(), .finished)
    }

    func testUnchangedFileStalls() throws {
        let file = dir.appendingPathComponent("c.part")
        try Data(count: 10).write(to: file)
        let watcher = DownloadWatcher(url: file, stallTimeout: 0.3)
        XCTAssertEqual(watcher.poll(), .downloading)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(watcher.poll(), .stalled)
    }

    func testShrinkingFileCountsAsActivity() throws {
        let file = dir.appendingPathComponent("d.part")
        try Data(count: 1000).write(to: file)
        let watcher = DownloadWatcher(url: file, stallTimeout: 0.3)
        Thread.sleep(forTimeInterval: 0.4)
        try Data(count: 10).write(to: file)
        XCTAssertEqual(watcher.poll(), .downloading)
    }

    /// Safari downloads are `.download` folders whose contents grow.
    func testSafariStylePackageTracksContents() throws {
        let package = dir.appendingPathComponent("file.zip.download")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let inner = package.appendingPathComponent("file.zip")
        try Data(count: 100).write(to: inner)
        let watcher = DownloadWatcher(url: package, stallTimeout: 0.3)
        Thread.sleep(forTimeInterval: 0.4)
        try Data(count: 5000).write(to: inner)
        XCTAssertEqual(watcher.poll(), .downloading)
        try FileManager.default.removeItem(at: package)
        XCTAssertEqual(watcher.poll(), .finished)
    }

    func testSymlinkLoopDoesNotHang() throws {
        let package = dir.appendingPathComponent("loop.download")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("self"), withDestinationURL: package)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("root"), withDestinationURL: URL(fileURLWithPath: "/"))
        let start = Date()
        XCTAssertEqual(DownloadWatcher(url: package).poll(), .downloading)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "followed symlinks")
    }

    func testUnreadableFileDoesNotCrash() throws {
        let file = dir.appendingPathComponent("locked.part")
        try Data(count: 10).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        XCTAssertEqual(DownloadWatcher(url: file).poll(), .downloading)
    }

    /// A huge package picked by mistake must not freeze the app for long on each poll.
    func testStressLargePackagePollTime() throws {
        let package = dir.appendingPathComponent("big.download")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for i in 0..<5_000 {
            FileManager.default.createFile(atPath: package.appendingPathComponent("\(i)").path, contents: Data(count: 1))
        }
        let watcher = DownloadWatcher(url: package)
        let start = Date()
        XCTAssertEqual(watcher.poll(), .downloading)
        let elapsed = Date().timeIntervalSince(start)
        print("Polling a 5,000-file package took \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 0.5)
    }
}
