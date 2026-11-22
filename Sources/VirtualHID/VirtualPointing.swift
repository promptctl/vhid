import Foundation
import Pointing
import Timeline

/// The pointing input report as the driver's packed `pointing_input` lays it out: a
/// 32-bit little-endian button field, then x, y, vertical wheel and horizontal wheel as
/// one signed byte each. 8 bytes, and no report id: the pointing collection is its own
/// device to the driver, unlike the keyboard whose report names its collection.
///
/// Built from the buttons that are down and the motion of this one report, and from
/// nothing else, for the reason `KeyboardReport` gives. [LAW:one-source-of-truth]
struct PointingReport {
    let buttons: UInt32
    let move: Move
    let scroll: Scroll

    init(held: Set<Button>, move: Move, scroll: Scroll) {
        buttons = Button.field(held)
        self.move = move
        self.scroll = scroll
    }

    var bytes: [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: buttons >> (8 * $0)) }
            + [move.x, move.y, scroll.vertical, scroll.horizontal].map { UInt8(bitPattern: $0.value) }
    }
}

/// The virtual mouse, spoken to in the device's own vocabulary: a button goes down, the
/// pointer moves by so many counts, the wheel rolls, and the device works out what to send.
///
/// It holds the set of buttons that are down and derives every report from that set, so
/// motion and wheel reports carry the buttons held - which is what makes a drag a button
/// down, moves, and a release, with nothing composed by the caller. The device knows only
/// deltas: where the pointer *is* is a fact of the window server, which the process that
/// can read it turns into a sequence of deltas above this seam. [LAW:one-way-deps]
///
/// **The calling process must be root**, for the reason `DaemonConnection` gives.
public final class VirtualPointing: Sendable {
    private let daemon: DaemonConnection
    /// The buttons held, kept by the rule `Held` gives, and every report a reading of them.
    private let buttons: HeldDevice<Button>

    /// The buttons the driver may be holding: what a release must clear.
    public var buttonsDown: Set<Button> { buttons.down }

    /// Over a connection the keyboard may share: pqrs's daemon keeps one keyboard and one
    /// pointing device per client connection, so the two devices of one client ride one
    /// socket, and the daemon's `erase_client` takes both when it closes.
    public init(daemon: DaemonConnection) {
        self.daemon = daemon
        buttons = HeldDevice(daemon: daemon, report: .postPointingInputReport, reset: .pointingReset)
    }

    /// Brings the device up and waits for the daemon's word that it is ready, by
    /// `deadline`. `pointing_initialize` carries no parameters: the driver's pointing
    /// collection has one identity, unlike the keyboard's vendor and product.
    @discardableResult
    public func start(by deadline: Deadline) throws -> Startup {
        try daemon.initialize(.pointingInitialize, [], until: .pointingReady, by: deadline)
    }

    /// Holds `button` down.
    public func down(_ button: Button, by deadline: Deadline) throws {
        try post(move: .none, scroll: .none, by: deadline) { $0.asked.union([button]) }
    }

    /// Every button up. Posted unconditionally, for the reason the keyboard's release is:
    /// a button the driver believes is down is a drag macOS continues into whatever the
    /// pointer crosses next.
    public func releaseAll(by deadline: Deadline) throws {
        try post(move: .none, scroll: .none, by: deadline) { _ in [] }
    }

    /// Holds exactly `buttons`, releasing whatever else is down: left and right held to
    /// left alone without ending the left drag. Always posts, for the reason `releaseAll`
    /// does.
    public func hold(_ buttons: Set<Button>, by deadline: Deadline) throws {
        try post(move: .none, scroll: .none, by: deadline) { _ in buttons }
    }

    /// Moves by `delta`, with whatever is held still held.
    public func move(_ delta: Move, by deadline: Deadline) throws {
        try post(move: delta, scroll: .none, by: deadline) { $0.asked }
    }

    /// Rolls the wheel by `delta`, with whatever is held still held.
    public func scroll(_ delta: Scroll, by deadline: Deadline) throws {
        try post(move: .none, scroll: delta, by: deadline) { $0.asked }
    }

    /// Clears the device's own state as well as this side's, with `pointingReset`.
    public func reset(by deadline: Deadline) throws {
        try buttons.reset(by: deadline)
    }

    /// Posts the report for the buttons `change` makes of the record, with this report's
    /// motion.
    private func post(move: Move, scroll: Scroll, by deadline: Deadline, holding change: (Held<Button>) -> Set<Button>) throws {
        try buttons.post(by: deadline, { change($0) }) { PointingReport(held: $0, move: move, scroll: scroll).bytes }
    }
}
