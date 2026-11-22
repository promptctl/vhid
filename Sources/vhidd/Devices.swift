import Installations
import Foundation
import Helper
import Keystrokes
import Pointing
import Synchronization
import Time
import VirtualHID

/// The devices as a seat serves them: an act by its client's deadline, the one release of
/// both, and the sweep. [LAW:decomposition] Admitting and letting go are the listener's
/// and the seat's; what an act and a release are belongs to the devices, and devices of a
/// test's own stand behind the real listener through this. One object per bring-up: the
/// devices a seat acted on are these, or they are gone.
protocol ServedDevices: AnyObject, Sendable {
    /// Does `act` by `deadline`, once `admit` - the seat's check and claim - has let it,
    /// both under the devices' lock taken by that deadline: an act whose turn comes after
    /// it is refused having claimed nothing and sent nothing. Throws what refused it.
    func act(_ act: Act, by deadline: Deadline, admitting admit: () throws -> Void) throws
    /// Releases both devices if `owed` says the release is still owed when its turn
    /// comes, then runs `after`, both under the lock: what a release frees is freed only
    /// once everything is up. Answers how it ended, or nil when it was not owed.
    func release(because reason: String, when owed: () -> Bool, then after: () -> Void) -> Released?
    /// Whether a release failed and none has succeeded since: keys or buttons a client
    /// left down that the devices are still releasing.
    var leftHeld: Bool { get }
    /// Lets go of what has been held too long, if the devices are free this moment: a
    /// client's keys past the limit, or, while `holding` says nobody holds the devices,
    /// whatever a failed release left. Nil when nothing was due.
    func sweep(holding: () -> pid_t?) -> Swept?
}

extension ServedDevices {
    /// A release owed whoever holds the devices, freeing nothing: vhidd's own start and stop.
    func releaseEverything(because reason: String) -> Released? {
        release(because: reason, when: { true }, then: {})
    }
}

/// How a release of both devices ended: what each would not do, if anything.
struct Released: Equatable, CustomStringConvertible {
    let keyboard: String?
    let mouse: String?

    var failed: Bool { keyboard != nil || mouse != nil }

    var description: String {
        [keyboard.map { "the keyboard would not release: \($0)" }, mouse.map { "the mouse would not release: \($0)" }]
            .compactMap { $0 }.joined(separator: "; ")
    }
}

/// A release that failed, as the client that left is told it: the devices are left held,
/// and vhidd goes on releasing them.
struct LeftHeld: Error, CustomStringConvertible {
    let released: Released
    var description: String { "the devices are left held: \(released); vhidd releases them again while nobody holds them" }
}

/// What a sweep let go of.
enum Swept: Equatable {
    /// Keys a client held past the limit with no report, and whose client it was.
    case keysPastLimit(KeysLetGo, by: pid_t?)
    /// What a failed release left down, released again while nobody held the devices.
    case leftHeld(Released)
}

/// Keys the deadline released, the limit they were held past, and the reason the release
/// failed if it did.
struct KeysLetGo: Equatable {
    let usages: [UInt16]
    let limit: Duration
    let failure: String?
}

/// A keyboard as vhidd drives it: every report by the deadline of the act that asked for
/// it, and the keys it may be holding. The device is the one record of those: it counts a
/// key whose request may have reached the driver unanswered, which no caller can.
/// [LAW:one-source-of-truth]
protocol HeldKeyboard: Sendable {
    var keysDown: Set<Usage> { get }
    func down(_ usage: Usage, by deadline: Deadline) throws
    func releaseAll(by deadline: Deadline) throws
    func hold(_ keys: HeldKeys, by deadline: Deadline) throws
}

/// The mouse as vhidd drives it, by the same rule as the keyboard.
protocol HeldMouse: Sendable {
    var buttonsDown: Set<Button> { get }
    func down(_ button: Button, by deadline: Deadline) throws
    func releaseAll(by deadline: Deadline) throws
    func hold(_ buttons: Set<Button>, by deadline: Deadline) throws
    func move(_ delta: Move, by deadline: Deadline) throws
    func scroll(_ delta: Scroll, by deadline: Deadline) throws
}

extension VirtualKeyboard: HeldKeyboard {}
extension VirtualPointing: HeldMouse {}

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
    private let mouse: any HeldMouse
    /// One report at a time, across both devices. [LAW:no-shared-mutable-globals] Each
    /// device keeps its own reports whole; this orders the two against each other, because
    /// they share the socket and the client: a keyboard report and a mouse report from one
    /// client are one sequence, and ordering them is cheaper than reasoning about two. It
    /// is also what holds a release of both as one act, which neither device can.
    ///
    /// A lock and not a queue, because every call here is a round trip the client is
    /// already waiting on: hopping to another thread to do synchronous work would add a
    /// hop and take away the ability to answer on the thread that asked. Taken by the act's
    /// deadline, so an act whose turn comes too late does nothing. [LAW:single-enforcer]
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

    /// How long a release vhidd makes of its own accord - a sweep's, or one a seat's
    /// ending owes - has, from when it is asked. A client's act has the client's deadline.
    static let releaseLimit: Duration = .seconds(2)

    private let limit: Duration
    private let timeline: Timeline
    /// When a client last asked for a report of either device, or a release last failed;
    /// under `device`.
    private var lastReport: Instant
    /// Whether the last release failed: read by `holding` from any thread, so under its own
    /// lock, and written only under `device`.
    private let owed = Mutex(false)

    init(keyboard: any HeldKeyboard, mouse: any HeldMouse, timeline: Timeline, limit: Duration = keyLimit) {
        self.keyboard = keyboard
        self.mouse = mouse
        self.limit = limit
        self.timeline = timeline
        self.lastReport = timeline.now()
    }

    var leftHeld: Bool { owed.withLock { $0 } }

    /// [LAW:dataflow-not-control-flow] Every act is the same act - take the devices by the
    /// deadline, admit it, do the one thing, answer with what happened - so the act is a
    /// value and this is one function, not eight copies of the same locking.
    func act(_ act: Act, by deadline: Deadline, admitting admit: () throws -> Void) throws {
        try device.withLock(by: deadline) {
            try admit()
            // Both ends: a report the driver took seconds to answer is the client being
            // active throughout, not idle.
            lastReport = timeline.now()
            defer { lastReport = timeline.now() }
            switch act {
            case .down(let usage): try keyboard.down(usage, by: deadline)
            case .releaseKeys: try keyboard.releaseAll(by: deadline)
            case .hold(let keys): try keyboard.hold(keys, by: deadline)
            case .buttonDown(let button): try mouse.down(button, by: deadline)
            case .releaseButtons: try mouse.releaseAll(by: deadline)
            case .holdButtons(let buttons): try mouse.hold(buttons, by: deadline)
            case .move(let delta): try mouse.move(delta, by: deadline)
            case .scroll(let delta): try mouse.scroll(delta, by: deadline)
            }
        }
    }

    /// Releases everything the client that just went away had left held, on both devices.
    ///
    /// [LAW:single-enforcer] A client that crashes mid-character leaves a key down, and a
    /// key the driver believes is down is one macOS repeats into whatever comes forward
    /// next - the failure this whole epic exists to avoid. A button left down is a drag
    /// macOS continues across whatever the pointer crosses. The client cannot clean up
    /// after itself in precisely the case that matters, so vhidd does it, on every way a
    /// connection can end - and on its own way in and out, for the same reason.
    ///
    /// Taken whoever is ahead, because a release refused would leave a key down; its
    /// deadline is made here, as it is asked.
    func release(because reason: String, when owed: () -> Bool, then after: () -> Void) -> Released? {
        let deadline = Deadline.within(Self.releaseLimit, on: timeline)
        return device.releasing {
            guard owed() else { return nil }
            defer { after() }
            return releaseBoth(because: reason, by: deadline)
        }
    }

    /// A release the keyboard refused is tried again one limit later, not on every sweep:
    /// a hung driver would otherwise hold every client's act behind a timed-out release
    /// four times a second, and log each one. Only while the devices are free: the sweep
    /// waits behind nobody's act. The tick is where its deadline is made.
    func sweep(holding: () -> pid_t?) -> Swept? {
        let deadline = Deadline.within(Self.releaseLimit, on: timeline)
        return device.whenFree { () -> Swept? in
            guard timeline.now() - lastReport >= limit else { return nil }
            let pid = holding()
            // [LAW:single-enforcer] What a failed release left is released here, while
            // nobody holds the devices, and never as part of another client's act.
            if pid == nil, leftHeld { return .leftHeld(releaseBoth(because: "releasing what a client left held", by: deadline)) }
            let held = keyboard.keysDown
            guard !held.isEmpty else { return nil }
            let failure = failure { try keyboard.releaseAll(by: deadline) }
            if failure != nil { lastReport = timeline.now() }
            return .keysPastLimit(KeysLetGo(usages: held.sorted().map(\.rawValue), limit: limit, failure: failure), by: pid)
        } ?? nil
    }

    /// Each device released whatever the other answered, by the one deadline, with the lock
    /// the caller holds across both: a report landing between them would be a key set down
    /// after the keyboard was cleared, with nothing left to catch it. Under `device`.
    private func releaseBoth(because reason: String, by deadline: Deadline) -> Released {
        let released = Released(keyboard: failure { try keyboard.releaseAll(by: deadline) }, mouse: failure { try mouse.releaseAll(by: deadline) })
        log(released.keyboard.map { "\(reason), and the keyboard would not release: \($0)" } ?? "\(reason); every key is up")
        log(released.mouse.map { "\(reason), and the mouse would not release: \($0)" } ?? "\(reason); every button is up")
        owed.withLock { $0 = released.failed }
        if released.failed { lastReport = timeline.now() }
        return released
    }

    private func failure(of release: () throws -> Void) -> String? {
        do {
            try release()
            return nil
        } catch {
            return "\(error)"
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
/// refusal from the rest; an act the seat turned away crosses under another, which is how
/// a client knows no key of its is held. [LAW:types-are-the-program]
///
/// An act's failure is said as failed only when nothing was sent: refused before its turn,
/// a value no report carries, or a report that never left. Anything else - a report that
/// may have reached the driver, or a failure this does not know the reach of - is said as
/// an outcome unknown, because a client told "failed" takes it that nothing happened.
func refusal(_ error: any Error) -> NSError {
    let code = switch error {
    case is Readiness.Refused: Installation.devicesDownCode
    case is Holder.Busy, is Seat.Ended, is Seat.Lost: Installation.seatRefusedCode
    case let unanswered as Unanswered: unanswered.mayHaveReachedTheDriver ? Installation.outcomeUnknownCode : 1
    case is Deadline.Passed, is NotOnTheDevice, is TooManyKeys, is LeftHeld: 1
    default: Installation.outcomeUnknownCode
    }
    return NSError(domain: Installation.refusalDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
}
