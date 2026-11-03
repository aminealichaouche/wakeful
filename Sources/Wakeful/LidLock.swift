import AppKit
import IOKit

/// Locks the screen the way Apple menu → Lock Screen does.
enum ScreenLock {
    private typealias LockFunction = @convention(c) () -> Int32

    /// `SACLockScreenImmediate` from the system's login framework is what Lock Screen calls.
    /// It's private, so it's looked up at run time and Wakeful falls back if it's ever missing.
    private static let lockFunction: LockFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    static var canLockDirectly: Bool { lockFunction != nil }

    static func lock() {
        if let lockFunction {
            _ = lockFunction()
        } else {
            // Locks too when "Require password after screen saver begins" is set to immediately.
            ScreenSaver.start()
        }
    }
}

/// Reports the laptop lid opening and closing, from the power manager's clamshell notification.
final class LidMonitor {
    /// `kIOPMMessageClamshellStateChange`: iokit_family_msg(sub_iokit_powermanagement, 0x100).
    static let clamshellStateChange: UInt32 = 0xE003_4100
    private static let clamshellClosedBit: UInt = 1 << 0

    private let onChange: (_ isClosed: Bool) -> Void
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private(set) var isRunning = false

    init(onChange: @escaping (_ isClosed: Bool) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Whether the lid is closed now, or nil on Macs without one.
    static var isLidClosed: Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    func start() {
        guard !isRunning else { return }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, message, argument in
            guard let context, message == LidMonitor.clamshellStateChange else { return }
            let isClosed = UInt(bitPattern: argument) & LidMonitor.clamshellClosedBit != 0
            Unmanaged<LidMonitor>.fromOpaque(context).takeUnretainedValue().onChange(isClosed)
        }, context, &notifier)
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return
        }
        self.port = port
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        IOObjectRelease(notifier)
        notifier = 0
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }
}

/// "Lock Mac When Lid Is Closed": during a session, closing the lid locks the Mac. A Mac kept
/// awake with the lid shut (closed-display mode, or an external display) would otherwise stay
/// unlocked, because the lock normally comes from going to sleep.
final class LidLock {
    private let manager: SessionManager
    private let settings: Settings
    private let lock: () -> Void
    private var lidWasClosed: Bool?
    private lazy var monitor = LidMonitor { [weak self] isClosed in self?.lidChanged(isClosed: isClosed) }

    init(manager: SessionManager, settings: Settings, lock: @escaping () -> Void = ScreenLock.lock) {
        self.manager = manager
        self.settings = settings
        self.lock = lock
    }

    var isWatching: Bool { monitor.isRunning }

    func start() {
        lidWasClosed = LidMonitor.isLidClosed
        monitor.start()
    }

    func stop() {
        monitor.stop()
    }

    /// Locks only as the lid goes from open to closed, so a repeated "closed" message, or
    /// starting Wakeful with the lid already shut, never locks.
    func lidChanged(isClosed: Bool) {
        defer { lidWasClosed = isClosed }
        guard isClosed, lidWasClosed != true, manager.isActive, settings.lockWhenLidClosed else { return }
        lock()
    }
}
