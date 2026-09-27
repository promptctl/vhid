import Foundation
import Helper

/// The most recent thing that went wrong in this daemon, kept for a client that asks
/// after the fact.
///
/// A daemon's only other voice is its log, which a person reads only once they already
/// suspect something. This is what vhid's menu bar item shows beside doctor's rows.
///
/// [LAW:no-shared-mutable-globals] One instance, written only through `record` and read
/// only through `current`, under its own lock. It is a global because the failures it
/// hears of happen all over the daemon - admission, bring-up, the devices - and threading
/// one value through each of them would add a parameter to every layer for a fact none of
/// them reads. It touches no installation, so the test bundle can link it.
final class LastFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var last: DaemonFailure?

    func record(_ text: String, at: Date = Date()) {
        lock.withLock { last = DaemonFailure(text: text, at: at) }
    }

    var current: DaemonFailure? { lock.withLock { last } }
}

let lastFailure = LastFailure()
