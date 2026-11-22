import DriverExtension
import Foundation
import Keystrokes
import Timeline

/// The keyboard input report as the driver's packed `keyboard_input` lays it out: report
/// id 1, one byte of modifier bits, one reserved byte, then 32 little-endian usages for
/// the keys held. 67 bytes.
///
/// It is built from the keys that are down and from nothing else, and no caller builds
/// one. [LAW:one-source-of-truth] A report a caller could compose is a report that can
/// disagree with what the device is holding, and that disagreement has one shape: a key
/// the driver believes is down that nobody remembers pressing, which macOS then repeats.
struct KeyboardReport {
    let modifiers: UInt8
    let usages: [UInt16]

    init(held: Set<Usage>) throws {
        var modifiers: UInt8 = 0
        var usages: [UInt16] = []
        // Sorted so one set of held keys has one encoding: a report that varies with a
        // hash seed is a report no test can pin and no capture can be compared against.
        for usage in try HeldKeys(held).usages.sorted() {
            if let bit = usage.modifierBit { modifiers |= bit } else { usages.append(usage.rawValue) }
        }
        self.modifiers = modifiers
        self.usages = usages
    }

    var bytes: [UInt8] {
        let padded = usages + Array(repeating: 0, count: HeldKeys.capacity - usages.count)
        return [1, modifiers, 0] + padded.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
    }
}

/// The virtual keyboard, spoken to in the device's own vocabulary: a usage goes down, a
/// usage comes up, and the device works out what to send.
///
/// It holds the set of keys that are down and derives every report from that set, so the
/// caller never composes one and the two can never disagree. What a caller decides is
/// *when*, and by when - this type posts a report and waits for the daemon's answer by the
/// caller's deadline, and nothing here paces a burst, because the pacing a burst needs is
/// not a fact about the device.
///
/// **The calling process must be root**, for the reason `DaemonConnection` gives.
public final class VirtualKeyboard: Sendable {
    /// The device's identity, three uint64 in this order. All three are
    /// `strong_typedef`s over `uint64_t`, so the payload is 24 bytes; the
    /// reasonable-looking reading - two 16-bit ids and a byte - is five bytes long, well
    /// formed, and initializes a device that is not the one asked for.
    ///
    /// The numbers come from `VirtualKeyboardIdentity` rather than sitting inline,
    /// because the Keyboard Setup Assistant's cache key - which the daemon files under and
    /// `vhid doctor` reads back - is built out of the same three. [LAW:one-source-of-truth]
    static let parameters: [UInt8] = [
        VirtualKeyboardIdentity.vendorID,
        VirtualKeyboardIdentity.productID,
        VirtualKeyboardIdentity.countryCode,
    ].flatMap { (value: UInt64) in (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    private let daemon: DaemonConnection

    /// The keys held, kept by the rule `Held` gives, and every report a reading of them.
    /// Nothing outside this type may set them.
    private let keys: HeldDevice<Usage>

    /// The keys the driver may be holding: what a release must clear.
    public var keysDown: Set<Usage> { keys.down }

    /// Connects to the daemon and takes nothing else on faith. The device is not up until
    /// `start` says so.
    ///
    /// `whenLost` is told, once and from another thread, when the daemon's connection ends
    /// underneath this device: the daemon exited, the socket failed, or the driver went
    /// away. Every call after
    /// that throws the same failure, so a caller that presses keys and stops can leave the
    /// default; a process holding the device open across silences is the one that needs to
    /// hear, because nothing it does in between would tell it.
    public convenience init(whenLost: @escaping @Sendable (DaemonError) -> Void = { _ in }) throws {
        self.init(daemon: try DaemonConnection(whenLost: whenLost))
    }

    /// Over a connection the mouse may share, for the reason `VirtualPointing` gives.
    public init(daemon: DaemonConnection) {
        self.daemon = daemon
        keys = HeldDevice(daemon: daemon, report: .postKeyboardInputReport, reset: .keyboardReset)
    }

    /// Brings the device up and waits for the daemon's word that it is ready, by
    /// `deadline`.
    ///
    /// Expect close to a second of that even on a device that came up at once: the daemon
    /// asks the driver whether the keyboard is ready on a one-second timer, so readiness
    /// is discovered on the next tick rather than when it happened. The number is pqrs's
    /// poll interval, not the hardware, and it is the reason a connection is meant to be
    /// held open rather than made per call - a client that connects for each call pays it
    /// every time.
    @discardableResult
    public func start(by deadline: Deadline) throws -> Startup {
        try daemon.initialize(.keyboardInitialize, Self.parameters, until: .keyboardReady, by: deadline)
    }

    /// Holds `usage` down.
    public func down(_ usage: Usage, by deadline: Deadline) throws {
        try post(by: deadline) { $0.asked.union([usage]) }
    }

    public func up(_ usage: Usage, by deadline: Deadline) throws {
        try post(by: deadline) { $0.asked.subtracting([usage]) }
    }

    /// Every key up, which is what a report of nothing held says. This is the line between
    /// a run that ends and a key the driver goes on reporting for macOS to repeat, so it
    /// posts unconditionally rather than only when something is recorded as down.
    public func releaseAll(by deadline: Deadline) throws {
        try post(by: deadline) { _ in [] }
    }

    /// Holds exactly `keys`, releasing whatever else is down.
    ///
    /// A non-empty set equal to the one the driver last acknowledged posts nothing: it is
    /// a player saying it is still alive while a key stays down, and a repeated report
    /// would reach macOS as nothing at best. The client was marked alive by the call
    /// before it got here, which is what keeps the keys past the daemon's limit. An empty
    /// set always posts, as `releaseAll` does. The skip needs the set settled, which a
    /// request that may have reached the driver unanswered unsettles, so the retry of such
    /// a `hold` always posts.
    public func hold(_ keys: HeldKeys, by deadline: Deadline) throws {
        try post(by: deadline) { keys.usages.isEmpty || !$0.settled || $0.down != keys.usages ? keys.usages : nil }
    }

    /// Clears the device's own state as well as this side's, with `keyboardReset`.
    public func reset(by deadline: Deadline) throws {
        try keys.reset(by: deadline)
    }

    /// Posts the report for the keys `change` makes of the record.
    ///
    /// `TooManyKeys` is this side refusing with nothing on the wire - the driver did not
    /// see that key, and a record that claimed otherwise would re-encode the same
    /// over-capacity set and throw again on every later post.
    private func post(by deadline: Deadline, _ change: (Held<Usage>) -> Set<Usage>?) throws {
        try keys.post(by: deadline, change) { try KeyboardReport(held: $0).bytes }
    }
}
