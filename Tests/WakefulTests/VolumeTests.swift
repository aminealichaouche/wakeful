import Foundation
import XCTest
@testable import Wakeful

/// Classification of mounts, from descriptions recorded on real Macs.
final class VolumeClassificationTests: XCTestCase {
    private func local(_ mountPoint: String, fs: String = "apfs", hidden: Bool = false, root: Bool = false,
                       disk: DiskRecord?) -> MountRecord {
        MountRecord(mountPoint: mountPoint, source: "/dev/disk9s1", fileSystem: fs, isLocal: true,
                    isHidden: hidden, isRoot: root, disk: disk)
    }

    private let internalSSD = DiskRecord(model: "APPLE SSD AP1024Z", protocolName: "Apple Fabric", isInternal: true,
                                         uuid: "F266EFF7-B017-4A0F-A98E-318CAA3CF4AB", name: "Macintosh HD")
    private let userDiskImage = DiskRecord(model: "Disk Image", protocolName: "Virtual Interface", isInternal: nil,
                                           isRemovable: true, isEjectable: true, uuid: "BD9E9466-1501-3718-9789-4864CDD60AF1",
                                           name: "Installer",
                                           devicePath: "IOService:/IOResources/IOHDIXController/IOHDIXHDDriveOutKernel@4/IODiskImageBlockStorageDeviceOutKernel")
    private let usbDrive = DiskRecord(model: "Samsung PSSD T7", protocolName: "USB", isInternal: false,
                                      uuid: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", name: "T7")

    func testInternalAndSystemVolumes() {
        XCTAssertNil(Volumes.classify(local("/", root: true, disk: internalSSD)), "startup disk")
        XCTAssertNil(Volumes.classify(local("/System/Volumes/Data", hidden: true, disk: internalSSD)))
        XCTAssertNil(Volumes.classify(local("/System/Volumes/Preboot", disk: internalSSD)), "system path even if not hidden")
        XCTAssertEqual(Volumes.classify(local("/Volumes/Second Partition", disk: internalSSD)), .internal)
    }

    func testDiskImagesNeverCountAsDrives() {
        XCTAssertEqual(Volumes.classify(local("/Volumes/Installer", fs: "hfs", disk: userDiskImage)), .diskImage)
        // Other ways macOS has described disk images.
        var older = userDiskImage
        older.protocolName = "Disk Image"
        older.model = nil
        XCTAssertEqual(Volumes.classify(local("/Volumes/Old", disk: older)), .diskImage)
        var pathOnly = userDiskImage
        pathOnly.protocolName = nil
        pathOnly.model = nil
        XCTAssertEqual(Volumes.classify(local("/Volumes/Path", disk: pathOnly)), .diskImage)
        // Simulator runtimes and system cryptexes are disk images and also hidden.
        XCTAssertNil(Volumes.classify(local("/Library/Developer/CoreSimulator/Volumes/iOS_24A434", hidden: true,
                                            disk: userDiskImage)))
    }

    func testPhysicalExternalDrives() {
        XCTAssertEqual(Volumes.classify(local("/Volumes/T7", disk: usbDrive)), .external)
        var thunderbolt = usbDrive
        thunderbolt.protocolName = "PCI-Express"
        XCTAssertEqual(Volumes.classify(local("/Volumes/TB", disk: thunderbolt)), .external)
        // SD card in a built-in reader: internal device, removable media.
        let sdCard = DiskRecord(model: "SD Card Reader", protocolName: "Secure Digital", isInternal: true,
                                isRemovable: true, isEjectable: true, name: "CAMERA")
        XCTAssertEqual(Volumes.classify(local("/Volumes/CAMERA", fs: "msdos", disk: sdCard)), .external)
        // Hidden external volumes (e.g. a backup drive's system partitions) are ignored.
        XCTAssertNil(Volumes.classify(local("/Volumes/.timemachine/x", hidden: true, disk: usbDrive)))
    }

    func testNetworkShares() {
        for (source, fs) in [("//amine@192.168.50.197/Everything", "smbfs"), ("afp://nas.local/Media", "afpfs"),
                             ("nas.local:/export/media", "nfs"), ("https://dav.example.com/files", "webdav")] {
            let record = MountRecord(mountPoint: "/Volumes/X", source: source, fileSystem: fs, isLocal: false,
                                     isHidden: false, isRoot: false, disk: nil)
            XCTAssertEqual(Volumes.classify(record), .network, source)
        }
        var flagged = local("/Volumes/Flagged", disk: usbDrive)
        flagged.disk?.isNetwork = true
        XCTAssertEqual(Volumes.classify(flagged), .network, "DiskArbitration says network")
    }

    func testVirtualMountsAreIgnored() {
        let autofs = MountRecord(mountPoint: "/System/Volumes/Data/home", source: "map auto_home", fileSystem: "autofs",
                                 isLocal: false, isHidden: true, isRoot: false, disk: nil)
        XCTAssertNil(Volumes.classify(autofs))
        let deviceFS = MountRecord(mountPoint: "/Users/x/Library/Developer/CoreDevice/DeviceFS", source: "devices",
                                   fileSystem: "devicefs", isLocal: true, isHidden: false, isRoot: false, disk: nil)
        XCTAssertNil(Volumes.classify(deviceFS))
        let unknownLocal = MountRecord(mountPoint: "/Volumes/FUSE", source: "fuse-t", fileSystem: "nfs", isLocal: true,
                                       isHidden: false, isRoot: false, disk: nil)
        XCTAssertNil(Volumes.classify(unknownLocal), "local mount without a disk")
    }

    func testIdentityAndNames() {
        let drive = Volumes.volume(for: local("/Volumes/T7", disk: usbDrive))
        XCTAssertEqual(drive?.id, "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")
        XCTAssertEqual(drive?.name, "T7")
        var noUUID = usbDrive
        noUUID.uuid = nil
        noUUID.name = nil
        XCTAssertEqual(Volumes.volume(for: local("/Volumes/OLD DRIVE", disk: noUUID))?.id, "name:OLD DRIVE")
        let share = Volumes.volume(for: MountRecord(mountPoint: "/Volumes/Everything-1", source: "//amine@NAS.local/Everything",
                                                    fileSystem: "smbfs", isLocal: false, isHidden: false, isRoot: false, disk: nil))
        XCTAssertEqual(share?.id, "nas.local/Everything")
        XCTAssertEqual(share?.name, "Everything", "share name, not the -1 mount point")
    }

    func testNetworkShareIDs() {
        let cases: [(String, String)] = [
            ("//amine@192.168.50.197/Everything", "192.168.50.197/Everything"),
            ("//192.168.50.197/Everything", "192.168.50.197/Everything"),
            ("//someone-else@192.168.50.197/Everything/", "192.168.50.197/Everything"),
            ("//amine@NAS.LOCAL/My%20Share", "nas.local/My Share"),
            ("smb://user;DOMAIN@Server/Share", "server/Share"),
            ("afp://nas.local/Media", "nas.local/Media"),
            ("nas.local:/export/media", "nas.local:/export/media"),
            ("https://dav.example.com/files/", "dav.example.com/files"),
            ("//host", "host"),
            ("", ""),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(Volumes.networkShareID(source), expected, source)
        }
    }
}

/// Reads this Mac's real mount table.
final class LiveVolumeTests: XCTestCase {
    private var attached: [String] = []

    override func tearDown() {
        for mountPoint in attached {
            shell("/usr/bin/hdiutil detach -force -quiet \"$1\"", [mountPoint])
        }
    }

    func testCurrentMountsClassifySafely() {
        let records = Volumes.mountRecords()
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.contains { $0.isRoot }, "startup disk is listed")
        let volumes = Volumes.mounted()
        XCTAssertFalse(volumes.contains { $0.mountPoint == "/" })
        XCTAssertFalse(volumes.contains { $0.mountPoint.hasPrefix("/System/Volumes/") })
        // Anything mounted from a disk image (simulators, cryptexes, installers) is never "external".
        for record in records where record.disk.map(Volumes.isDiskImage) == true {
            XCTAssertNotEqual(Volumes.classify(record), .external, record.mountPoint)
        }
        // Network shares (e.g. a NAS) are never "external", and vice versa.
        for record in records where !record.isLocal {
            XCTAssertNotEqual(Volumes.classify(record), .external, record.mountPoint)
        }
    }

    func testMountedNetworkSharesAreDetected() throws {
        let shares = Volumes.mountRecords().filter { !$0.isLocal && !$0.isHidden && $0.fileSystem != "autofs" }
        try XCTSkipIf(shares.isEmpty, "no network share mounted on this Mac")
        let volumes = Volumes.mounted()
        for share in shares {
            let volume = volumes.first { $0.mountPoint == share.mountPoint }
            XCTAssertEqual(volume?.kind, .network, share.mountPoint)
            XCTAssertFalse(volume?.id.contains("@") ?? true, "user name stripped from \(share.source)")
        }
        XCTAssertTrue(RuleCondition.networkDrive(nil).isMet(in: SystemSnapshot(volumes: volumes)))
    }

    /// Mounts HFS+ and APFS disk images the way double-clicking a .dmg does.
    func testMountedDiskImagesAreNotExternalDrives() throws {
        let externalBefore = Volumes.mounted().filter { $0.kind == .external }
        let dir = makeTempDirectory()
        for fs in ["HFS+", "APFS"] {
            let name = "WakefulTest\(fs.filter(\.isLetter))\(Int.random(in: 1000...9999))"
            let image = dir.appendingPathComponent("\(name).dmg").path
            XCTAssertEqual(shell("/usr/bin/hdiutil create -quiet -size 8m -fs \"$1\" -volname \"$2\" \"$3\"",
                                 [fs, name, image]).status, 0)
            XCTAssertEqual(shell("/usr/bin/hdiutil attach -quiet \"$1\"", [image]).status, 0)
            attached.append("/Volumes/\(name)")
        }

        let volumes = Volumes.mounted()
        for mountPoint in attached {
            let volume = volumes.first { $0.mountPoint == mountPoint }
            XCTAssertEqual(volume?.kind, .diskImage, mountPoint)
        }
        XCTAssertEqual(volumes.filter { $0.kind == .external }, externalBefore, "a disk image showed up as a drive")
        if externalBefore.isEmpty {
            XCTAssertFalse(RuleCondition.externalDrive(nil).isMet(in: SystemSnapshot(volumes: volumes)))
        }
    }

    func testStressRepeatedMountTableReads() {
        let start = Date()
        for _ in 0..<300 { _ = Volumes.mounted() }
        let elapsed = Date().timeIntervalSince(start)
        print("300 mount table reads took \(String(format: "%.2f", elapsed))s")
        XCTAssertLessThan(elapsed, 10)
    }

    func testConcurrentReadsAreSafe() {
        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<40 { _ = Volumes.mounted() }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
    }
}
