import Installations
import Foundation
import Helper
import Keystrokes
import Pointing
import Timeline
import VirtualHID

/// The devices as the listener serves them: a client's acts, each by the deadline its seat
/// made when the act arrived, and the releases made on a client's behalf.
/// [LAW:decomposition] Admitting and letting go are the listener's; what a release is
/// belongs to the devices, and devices of a test's own stand behind the real listener
/// through this.
///
/// [LAW:parse-dont-validate] In the devices' own values: the seat parses the wire's
/// numbers before it claims anything, so an act refused for what it asked holds nothing.
protocol ServedDevices: AnyObject, Sendable {
    func down(_ usage: Usage, by deadline: Deadline) throws
    func releaseAll(by deadline: Deadline) throws
    func hold(_ keys: HeldKeys, by deadline: Deadline) throws
    func buttonDown(_ button: Button, by deadline: Deadline) throws
    func releaseButtons(by deadline: Deadline) throws
    func holdButtons(_ buttons: Set<Button>, by deadline: Deadline) throws
    func move(_ delta: Move, by deadline: Deadline) throws
    func scroll(_ delta: Scroll, by deadline: Deadline) throws
    /// Every key and button up, as one act by `deadline`: for a client taking devices
    /// whose last client's release failed.
    func release(by deadline: Deadline) throws
    /// Releases everything a client left held, however long its turn takes, and says
    /// whether it all came up.
    func releaseEverything(because reason: String) -> Release
    /// Releases the keyboard when a key has been down past the limit with no keyboard
    /// report, answering with what that let go of and whose it was, as `holder` names it
    /// then, or nil when nothing was due.
    func releaseKeysHeldPastLimit(heldBy holder: () -> pid_t?) -> KeysLetGo?
}

/// What a release made on a client's behalf came to. [LAW:no-silent-failure] A value and
/// not a line in the log, so whoever frees the devices after it knows whether they are
/// fit to hand on.
enum Release {
    case released
    case failed(Unreleased)
}

/// A release on a client's behalf that did not bring everything up: why, device by device.
struct Unreleased: Error, CustomStringConvertible {
    let reason: String
    let keyboard: (any Error)?
    let mouse: (any Error)?

    var description: String {
        "\(reason), and " + [keyboard.map { "the keyboard would not release: \($0)" }, mouse.map { "the mouse would not release: \($0)" }]
            .compactMap { $0 }.joined(separator: "; ")
    }
}

/// Keys the deadline released, the limit they were held past, the client that held them,
/// and the reason the release failed if it did.
struct KeysLetGo: Equatable {
    let usages: [UInt16]
    let limit: Duration
    let holder: pid_t?
    let failure: String?
}

/// A keyboard that says which keys it holds, and takes each report by a deadline. The
/// device is the one record of what is held: it counts a key whose request may have
/// reached the driver unanswered, which no caller can. [LAW:one-source-of-truth]
protocol HeldKeyboard: Sendable {
    var keysDown: Set<Usage> { get }
    func down(_ usage: Usage, by deadline: Deadline) throws
    func releaseAll(by deadline: Deadline) throws
    func hold(_ keys: HeldKeys, by deadline: Deadline) throws
}

extension VirtualKeyboard: HeldKeyboard {}

/// The mouse as the devices drive it: each report by a deadline. [LAW:locality-or-seam]
protocol HeldPointing: Sendable {
    func down(_ button: Button, by deadline: Deadline) throws
    func releaseAll(by deadline: Deadline) throws
    func hold(_ buttons: Set<Button>, by deadline: Deadline) throws
    func move(_ delta: Move, by deadline: Deadline) throws
    func scroll(_ delta: Scroll, by deadline: Deadline) throws
}

extension VirtualPointing: HeldPointing {}

/// The keyboard and the mouse, held open for as long as their connection to the daemon
/// lasts and served to one client at a time.
///
/// [LAW:no-ambient-temporal-coupling] Both are brought up once per connection and never
/// re-opened per client, because readiness is not instant: pqrs's daemon asks the driver whether a
/// device is ready on a one-second timer, so a connect-per-client daemon would put up to
/// a full second in front of every client's first keystroke, for a reason that has
/// nothing to do with the hardware. Paid once here, where nobody is waiting.
final class Devices: ServedDevices, @unchecked Sendable {
    /// The seams and not the drivers, so a test hands in devices of its own and the
    /// daemon hands in the real ones. [LAW:composability]
    private let keyboard: any HeldKeyboard
    private let mouse: any HeldPointing
    /// One report at a time, across both devices. [LAW:no-shared-mutable-globals] Each
    /// device keeps its own reports whole; this orders the two against each other, because
    /// they share the socket and the client: a keyboard report and a mouse report from one
    /// client are one sequence, and ordering them is cheaper than reasoning about two. It
    /// is also what holds a release of both as one act, which neither device can.
    ///
    /// A lock and not a queue, because every call here is a round trip the client is
    /// already waiting on: hopping to another thread to do synchronous work would add a
    /// hop and take away the ability to answer on the thread that asked. Taken by the
    /// act's deadline, so an act whose turn comes too late is refused and not done.
    private let device = TimedLock()

    /// How long a key may stay down with no keyboard report before the daemon lets it go.
    ///
    /// A stopped client that is still connected - suspended mid-chord, paused in a
    /// debugger, a hung MCP host - keeps its key down, and macOS repeats it into whatever
    /// app is in front. A modifier held for a click, scroll or drag spans a pointer gesture
    /// measured at about 150ms across a whole desk; a player holding a key longer repeats
    /// `hold`, which posts nothing and keeps the key only while the player keeps asking.
    /// Buttons are not timed, because a replayed pointer script holds one across gaps.
    ///
    /// Any report counts as the client being alive, pointer ones included: a modifier held
    /// through a drag the client paces over seconds is live, and a stopped client sends
    /// nothing at all.
    static let keyLimit = HeldKeys.silenceLimit

    /// How long a release made on a client's behalf has for each device's report, counted
    /// once its turn has come: a release waits out the act ahead of it rather than be given
    /// up on, because a release given up on is a key left down.
    static let releaseLimit: Duration = .seconds(2)

    private let limit: Duration
    private let timeline: Timeline
    /// When a client last asked for a report of either device, on `timeline`; under `device`.
    private var lastReport: Duration

    init(keyboard: any HeldKeyboard, mouse: any HeldPointing, limit: Duration = keyLimit, timeline: Timeline) {
        self.keyboard = keyboard
        self.mouse = mouse
        self.limit = limit
        self.timeline = timeline
        self.lastReport = timeline.now()
    }

    /// [LAW:dataflow-not-control-flow] Every call is the same act - take the devices by
    /// the act's deadline, do one thing to them - so they are one function taking the
    /// thing to do, not eight copies of the same locking.
    private func attempt(by deadline: Deadline, _ act: () throws -> Void) throws {
        try device.withLock(by: deadline) {
            // Both ends: a report the driver took seconds to answer is the client being
            // active throughout, not idle.
            lastReport = timeline.now()
            defer { lastReport = timeline.now() }
            try act()
        }
    }

    /// What an act threw, for the releases that report a failure rather than throw it.
    private func outcome(_ act: () throws -> Void) -> (any Error)? {
        do {
            try act()
            return nil
        } catch {
            return error
        }
    }

    func down(_ usage: Usage, by deadline: Deadline) throws {
        try attempt(by: deadline) { try keyboard.down(usage, by: deadline) }
    }

    func releaseAll(by deadline: Deadline) throws {
        try attempt(by: deadline) { try keyboard.releaseAll(by: deadline) }
    }

    func hold(_ keys: HeldKeys, by deadline: Deadline) throws {
        try attempt(by: deadline) { try keyboard.hold(keys, by: deadline) }
    }

    /// A release the keyboard refused is tried again one limit later, not on every sweep:
    /// a hung driver would otherwise hold every client's act behind a timed-out release
    /// four times a second, and log each one.
    ///
    /// Taken only when the devices are free at once: a client mid-act is a client alive,
    /// with nothing of its due, so the sweep waits behind no act and no act behind it
    /// for longer than one release. The holder is named under the devices' lock, where
    /// the keys it held were set, so the pid named is the one whose keys these were.
    func releaseKeysHeldPastLimit(heldBy holder: () -> pid_t?) -> KeysLetGo? {
        let due = device.whenFree { () -> KeysLetGo? in
            let held = keyboard.keysDown
            guard !held.isEmpty, timeline.now() - lastReport >= limit else { return nil }
            let failure = outcome { try keyboard.releaseAll(by: timeline.deadline(within: Self.releaseLimit)) }.map { "\($0)" }
            // Whatever the release came to: one that worked leaves nothing held for the time
            // to matter to, and one that did not is tried again a limit from now.
            lastReport = timeline.now()
            return KeysLetGo(usages: held.sorted().map(\.rawValue), limit: limit, holder: holder(), failure: failure)
        }
        switch due {
        case .took(let letGo): return letGo
        // A client mid-act is a client alive: nothing of its is due.
        case .busy: return nil
        }
    }

    func buttonDown(_ button: Button, by deadline: Deadline) throws {
        try attempt(by: deadline) { try mouse.down(button, by: deadline) }
    }

    func releaseButtons(by deadline: Deadline) throws {
        try attempt(by: deadline) { try mouse.releaseAll(by: deadline) }
    }

    func holdButtons(_ buttons: Set<Button>, by deadline: Deadline) throws {
        try attempt(by: deadline) { try mouse.hold(buttons, by: deadline) }
    }

    func move(_ delta: Move, by deadline: Deadline) throws {
        try attempt(by: deadline) { try mouse.move(delta, by: deadline) }
    }

    func scroll(_ delta: Scroll, by deadline: Deadline) throws {
        try attempt(by: deadline) { try mouse.scroll(delta, by: deadline) }
    }

    func release(by deadline: Deadline) throws {
        try attempt(by: deadline) {
            try keyboard.releaseAll(by: deadline)
            try mouse.releaseAll(by: deadline)
        }
    }

    /// Releases everything the client that just went away had left held, on both devices.
    ///
    /// [LAW:single-enforcer] A client that crashes mid-character leaves a key down, and a
    /// key the driver believes is down is one macOS repeats into whatever comes forward
    /// next - the failure this whole epic exists to avoid. A button left down is a drag
    /// macOS continues across whatever the pointer crosses. The client cannot clean up
    /// after itself in precisely the case that matters, so vhidd does it, on every
    /// way a connection can end - and on its own way out, for the same reason. Each device
    /// is released whatever the other answered, each with a limit of its own, and the lock
    /// is held across both: a report landing between them would be a key set down after the
    /// keyboard was cleared, with nothing left to catch it.
    ///
    /// What came of it is answered, and told once here: a failure as the daemon's own, so
    /// `vhid doctor` and the menu read it back. [LAW:single-enforcer]
    func releaseEverything(because reason: String) -> Release {
        device.withLock {
            let key = outcome { try keyboard.releaseAll(by: timeline.deadline(within: Self.releaseLimit)) }
            let button = outcome { try mouse.releaseAll(by: timeline.deadline(within: Self.releaseLimit)) }
            guard key != nil || button != nil else {
                log("\(reason); every key and button is up")
                return .released
            }
            let failed = Unreleased(reason: reason, keyboard: key, mouse: button)
            logFailure("\(failed)")
            return .failed(failed)
        }
    }

}

/// An error a client can actually receive.
///
/// NSXPC carries only what it can encode, and a Swift error is not that: an unencodable
/// error crosses as a generic failure that names nothing, which is the same as saying
/// "it did not work" to an operator holding a half-typed line. So the description is made
/// on this side, where the real error still exists, and carried by a plain `NSError` - the
/// one class the reply admits, and one every client has. A subclass of it would be
/// archived under a name no client links, and would not decode. [LAW:no-silent-failure]
/// `Installation.refusalDomain` and not the serving installation's Mach service name: the
/// domain says what kind of thing refused, which is the same fact for every installation
/// built from this package, including ones it has never heard of. It being a static is
/// also what lets this file be linked into the test bundle - reaching for the
/// process-wide installation there would run its initializer against the test runner's
/// own arguments, find no `--service`, and end the test process with the refusal it is
/// written to make. [LAW:decomposition]
///
/// Devices that are not up cross under their own code, which is how doctor tells that
/// refusal from the rest; a refusal that proves this connection holds nothing crosses under
/// another, which is how a client knows no key of its is held. [LAW:types-are-the-program]
func refusal(_ error: any Error) -> NSError {
    let (code, said) = switch error {
    case is Readiness.Refused: (Installation.devicesDownCode, "\(error)")
    case is Holder.Busy, is Holder.LeftHeld, is Seat.Ended, is Seat.Lost: (Installation.seatRefusedCode, "\(error)")
    // Late proves this act was not done, and nothing about the acts before it: a key one
    // of them set down may still be held, so it is not the code that says none is.
    case is Late: (1, "\(error)")
    default: (1, "\(error)")
    }
    return NSError(domain: Installation.refusalDomain, code: code, userInfo: [NSLocalizedDescriptionKey: said])
}
