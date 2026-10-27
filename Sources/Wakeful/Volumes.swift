import DiskArbitration
import Foundation

/// A mounted volume, as custom rules see it.
struct MountedVolume: Hashable {
    enum Kind: Hashable {
        /// A physical drive that isn't built in, or removable media such as an SD card.
        case external
        /// A file share from another computer or NAS (SMB, AFP, NFS, WebDAV).
        case network
        /// A mounted .dmg or similar image. Never counts as a drive.
        case diskImage
        case `internal`
    }

    let kind: Kind
    /// Stable identity: the volume UUID for drives, "host/share" for network shares.
    let id: String
    let name: String
    let mountPoint: String
}

/// Raw facts about one mount, from `getfsstat` and DiskArbitration.
struct MountRecord {
    var mountPoint: String
    /// Where it's mounted from: "/dev/disk4s1", "//user@host/share", "host:/export"…
    var source: String
    var fileSystem: String
    var isLocal: Bool
    /// Hidden from Finder (MNT_DONTBROWSE): system volumes, simulators, device mounts.
    var isHidden: Bool
    var isRoot: Bool
    var disk: DiskRecord?
}

/// The DiskArbitration description of a mounted device.
struct DiskRecord {
    var model: String?
    var protocolName: String?
    var isInternal: Bool?
    var isRemovable = false
    var isEjectable = false
    var isNetwork = false
    var uuid: String?
    var name: String?
    var devicePath: String?
}

enum Volumes {
    /// Volumes that rules can refer to. Never blocks: unresponsive network shares are listed
    /// from the kernel's cached mount table instead of being asked for details.
    static func mounted() -> [MountedVolume] {
        mountRecords().compactMap(volume(for:))
    }

    static func volume(for record: MountRecord) -> MountedVolume? {
        guard let kind = classify(record) else { return nil }
        switch kind {
        case .network:
            return MountedVolume(kind: kind, id: networkShareID(record.source),
                                 name: networkShareName(record), mountPoint: record.mountPoint)
        case .external, .diskImage, .internal:
            let name = record.disk?.name ?? (record.mountPoint as NSString).lastPathComponent
            let id = record.disk?.uuid.map { $0.uppercased() } ?? "name:" + name
            return MountedVolume(kind: kind, id: id, name: name, mountPoint: record.mountPoint)
        }
    }

    /// What kind of volume a mount is, or nil for system and virtual mounts rules should ignore.
    static func classify(_ record: MountRecord) -> MountedVolume.Kind? {
        if record.isRoot || record.isHidden || record.mountPoint.hasPrefix("/System/Volumes/")
            || ["autofs", "devfs", "devicefs"].contains(record.fileSystem) {
            return nil
        }
        if !record.isLocal || record.disk?.isNetwork == true {
            return .network
        }
        guard let disk = record.disk else { return nil }
        // Checked before "removable": macOS marks disk images removable and ejectable too.
        if isDiskImage(disk) {
            return .diskImage
        }
        if disk.isInternal == false || disk.isRemovable || disk.isEjectable {
            return .external
        }
        return .internal
    }

    static func isDiskImage(_ disk: DiskRecord) -> Bool {
        disk.model == "Disk Image"
            || ["Disk Image", "Virtual Interface"].contains(disk.protocolName)
            || disk.devicePath.map { $0.contains("DiskImage") || $0.contains("IOHDIX") } == true
    }

    /// "//amine@NAS.local/My%20Share" → "nas.local/My Share". Drops the scheme and user name and
    /// lowercases the host, so the same share matches however it was connected.
    static func networkShareID(_ source: String) -> String {
        var rest = Substring(source)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        let hostEnd = rest.firstIndex(where: { $0 == "/" || $0 == ":" }) ?? rest.endIndex
        var host = rest[..<hostEnd]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        var path = String(rest[hostEnd...])
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return host.lowercased() + (path.removingPercentEncoding ?? path)
    }

    private static func networkShareName(_ record: MountRecord) -> String {
        let id = networkShareID(record.source)
        let share = id.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init)
        return share ?? (record.mountPoint as NSString).lastPathComponent
    }

    // MARK: - Reading the mount table

    private static let diskSession = DASessionCreate(kCFAllocatorDefault)

    static func mountRecords() -> [MountRecord] {
        // MNT_NOWAIT returns cached information instead of asking each file system, so a NAS
        // that has gone away can't hang this call.
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let capacity = Int(count) + 16
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let filled = getfsstat(buffer, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard filled > 0 else { return [] }

        return UnsafeBufferPointer(start: buffer, count: Int(filled)).map { entry in
            var entry = entry
            let source = string(from: &entry.f_mntfromname)
            let flags = Int32(bitPattern: entry.f_flags)
            return MountRecord(
                mountPoint: string(from: &entry.f_mntonname),
                source: source,
                fileSystem: string(from: &entry.f_fstypename),
                isLocal: flags & MNT_LOCAL != 0,
                isHidden: flags & MNT_DONTBROWSE != 0,
                isRoot: flags & MNT_ROOTFS != 0,
                disk: source.hasPrefix("/dev/") ? diskRecord(bsdName: String(source.dropFirst(5))) : nil
            )
        }
    }

    private static func diskRecord(bsdName: String) -> DiskRecord? {
        guard let session = diskSession,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        func value<T>(_ key: CFString) -> T? { description[key as String] as? T }
        let uuid: CFUUID? = value(kDADiskDescriptionVolumeUUIDKey)
        return DiskRecord(
            model: value(kDADiskDescriptionDeviceModelKey),
            protocolName: value(kDADiskDescriptionDeviceProtocolKey),
            isInternal: value(kDADiskDescriptionDeviceInternalKey),
            isRemovable: value(kDADiskDescriptionMediaRemovableKey) ?? false,
            isEjectable: value(kDADiskDescriptionMediaEjectableKey) ?? false,
            isNetwork: value(kDADiskDescriptionVolumeNetworkKey) ?? false,
            uuid: uuid.flatMap { CFUUIDCreateString(kCFAllocatorDefault, $0) as String? },
            name: value(kDADiskDescriptionVolumeNameKey),
            devicePath: value(kDADiskDescriptionDevicePathKey)
        )
    }

    private static func string<T>(from tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
