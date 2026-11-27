import Foundation
import IOKit.pwr_mgt

/// Holds a `PreventUserIdleSystemSleep` power assertion — what `caffeinate -i`
/// does — for the length of one script run (issue #59).
///
/// macOS idle sleep counts from the user's last input, not from whether a
/// process is busy, so a run that started on time could be frozen halfway when
/// the idle timer ran out. Only system sleep is held off: the display still
/// turns off, and closing a laptop lid or choosing Sleep still sleeps. IOKit
/// drops the assertion when the owning process exits, so a crash can't leave
/// the Mac awake for good.
struct IdleSleepAssertion {
    private let id: IOPMAssertionID

    /// `nil` when IOKit refuses. The run goes ahead regardless; it just isn't
    /// protected from idle sleep.
    init?(name: String) {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            NSLog("⚠️ IdleSleepAssertion: IOPMAssertionCreateWithName failed (\(result))")
            return nil
        }
        self.id = id
    }

    func release() {
        IOPMAssertionRelease(id)
    }
}
