import Foundation

/// Keeps the process running for the moment after it leaves the foreground, so a flush started
/// on the way to the background can finish. iOS suspends a backgrounded process almost at once;
/// a request in flight at that instant is sent, but its response reaches a suspended process and
/// the SDK never learns the batch landed. Holding a task assertion for the few hundred
/// milliseconds a flush needs makes "backgrounded → flushed → acknowledged" the normal case.
///
/// Built on `ProcessInfo.performExpiringActivity`, which works in apps and extensions alike and
/// needs no UIKit. Nothing here blocks the caller: the system runs the block on its own thread,
/// and that block is what waits.
final class ProcessHold: @unchecked Sendable {
    /// The longest the process is held open for one flush. A batch request is bounded under it,
    /// so a stalled ingest fails while the hold still stands rather than after it has lapsed.
    static let maximumHold: TimeInterval = 25

    private let gate = DispatchSemaphore(value: 0)

    init(reason: String) {
        #if !os(macOS)
        // Granted: block(false) runs and is parked until `release()` - or a ceiling, so a hung
        // request can never pin the app open. Refused, or granted then exhausted: block(true)
        // runs; nothing to hold. A surplus signal is harmless.
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { [self] expired in
            if expired {
                gate.signal()
                return
            }
            _ = gate.wait(timeout: .now() + Self.maximumHold)
        }
        #endif
    }

    /// The flush is done (or has failed and been requeued): let the process suspend.
    func release() {
        gate.signal()
    }
}
