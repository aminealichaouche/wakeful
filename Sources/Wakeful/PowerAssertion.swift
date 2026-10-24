import Foundation
import IOKit.pwr_mgt

/// An IOKit power assertion that is held until `release()` is called or the object is deallocated.
final class PowerAssertion {
    let type: String
    private var id: IOPMAssertionID = 0
    private var isHeld = false

    init?(type: String, reason: String) {
        self.type = type
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return nil }
        isHeld = true
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        isHeld = false
    }

    deinit {
        release()
    }

    /// Keeps the display awake (and therefore the system too).
    static let preventDisplaySleep = kIOPMAssertPreventUserIdleDisplaySleep as String
    /// Keeps the system awake but lets the display turn off.
    static let preventSystemSleep = kIOPMAssertPreventUserIdleSystemSleep as String
}
