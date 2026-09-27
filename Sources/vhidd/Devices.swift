import Installations
import Foundation
import Helper
import Keystrokes
import Pointing
import VirtualHID

/// The devices as the listener serves them: what a client is handed, and the release made
/// on a client's behalf when it goes. [LAW:decomposition] Admitting and letting go are the
/// listener's; what a release is belongs to the devices, and devices of a test's own stand
/// behind the real listener through this.
protocol ServedDevices: DeviceService {
    func releaseEverything(because reason: String)
    /// Releases the keyboard when a key has been down past the limit with no keyboard
    /// report, answering with what that let go of, or nil when nothing was due.
    func releaseKeysHeldPastLimit() -> KeysLetGo?
}

/// Keys the deadline released, the limit they were held past, and the reason the release
/// failed if it did.
struct KeysLetGo: Equatable {
    let usages: [UInt16]
    let limit: Duration
    let failure: String?
}

/// A keyboard that says which keys it holds. The device is the one record of that: it
/// counts a key whose request threw after reaching the driver, which no caller can.
/// [LAW:one-source-of-truth]
protocol HeldKeyboard: KeyPress {
    var keysDown: Set<Usage> { get }
}

extension VirtualKeyboard: HeldKeyboard {}

/// The keyboard and the mouse, held open for as long as their connection to the daemon
/// lasts and served to one client at a time.
///
/// [LAW:no-ambient-temporal-coupling] Both are brought up once per connection and never
/// re-opened per client, because readiness is not instant: pqrs's daemon asks the driver whether a
/// device is ready on a one-second timer, so a connect-per-client daemon would put up to
/// a full second in front of every client's first keystroke, for a reason that has
/// nothing to do with the hardware. Paid once here, where nobody is waiting.
final class Devices: NSObject, ServedDevices, @unchecked Sendable {
    /// The seams and not the drivers, so a test hands in devices of its own and the
    /// daemon hands in the real ones. [LAW:composability]
    private let keyboard: any HeldKeyboard
    private let mouse: any PointingDevice
    /// One report at a time, across both devices. [LAW:no-shared-mutable-globals] Each
    /// device keeps its own reports whole; this orders the two against each other, because
    /// they share the socket and the client: a keyboard report and a mouse report from one
    /// client are one sequence, and ordering them is cheaper than reasoning about two. It
    /// is also what holds a release of both as one act, which neither device can.
    ///
    /// A lock and not a queue, because every call here is a round trip the client is
    /// already waiting on: hopping to another thread to do synchronous work would add a
    /// hop and take away the ability to answer on the thread that asked.
    private let device = NSLock()

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
    static let keyLimit: Duration = .seconds(2)

    private let limit: Duration
    private let now: () -> ContinuousClock.Instant
    /// When a client last asked for a report of either device; under `device`.
    private var lastReport: ContinuousClock.Instant

    init(keyboard: any HeldKeyboard, mouse: any PointingDevice, limit: Duration = keyLimit,
         now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.keyboard = keyboard
        self.mouse = mouse
        self.limit = limit
        self.now = now
        self.lastReport = now()
    }

    /// [LAW:dataflow-not-control-flow] Every call is the same act - take the devices, do
    /// one thing to them, answer with what happened - so they are one function taking the
    /// thing to do, not eight copies of the same locking and error handling.
    private func attempt(_ act: () throws -> Void, _ reply: (Error?) -> Void) {
        device.lock()
        defer { device.unlock() }
        // Both ends: a report the driver took seconds to answer is the client being active
        // throughout, not idle.
        lastReport = now()
        let answered = outcome(of: act)
        lastReport = now()
        reply(answered)
    }

    /// The lock is the caller's to hold, so an act made of several is still one sequence.
    private func outcome(of act: () throws -> Void) -> Error? {
        do {
            try act()
            return nil
        } catch {
            return refusal(error)
        }
    }

    func down(usage: UInt16, reply: @escaping (Error?) -> Void) {
        attempt({ try keyboard.down(try Self.usage(usage)) }, reply)
    }

    func releaseAll(reply: @escaping (Error?) -> Void) {
        attempt({ try keyboard.releaseAll() }, reply)
    }

    /// [LAW:single-enforcer] More than a report carries is refused by `HeldKeys`, by name,
    /// before the device sees it. A usage named twice on the wire is one key held.
    func hold(usages: [UInt16], reply: @escaping (Error?) -> Void) {
        attempt({ try keyboard.hold(try HeldKeys(Set(usages.map(Self.usage)))) }, reply)
    }

    /// A release the keyboard refused is tried again one limit later, not on every sweep:
    /// a hung driver would otherwise hold every client's act behind a timed-out release
    /// four times a second, and log each one.
    func releaseKeysHeldPastLimit() -> KeysLetGo? {
        device.lock()
        defer { device.unlock() }
        let held = keyboard.keysDown
        guard !held.isEmpty, now() - lastReport >= limit else { return nil }
        let failure = outcome(of: keyboard.releaseAll).map { "\($0)" }
        if failure != nil { lastReport = now() }
        return KeysLetGo(usages: held.sorted().map(\.rawValue), limit: limit, failure: failure)
    }

    func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) {
        attempt({ try mouse.down(try Self.button(button)) }, reply)
    }

    func releaseButtons(reply: @escaping (Error?) -> Void) {
        attempt({ try mouse.releaseAll() }, reply)
    }

    func holdButtons(_ buttons: UInt32, reply: @escaping (Error?) -> Void) {
        attempt({ try mouse.hold(Button.buttons(in: buttons)) }, reply)
    }

    func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) {
        attempt({ try mouse.move(by: Move(x: try Self.count(x), y: try Self.count(y))) }, reply)
    }

    func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) {
        attempt({ try mouse.scroll(by: Scroll(vertical: try Self.count(vertical), horizontal: try Self.count(horizontal))) }, reply)
    }

    /// Releases everything the client that just went away had left held, on both devices.
    ///
    /// [LAW:single-enforcer] A client that crashes mid-character leaves a key down, and a
    /// key the driver believes is down is one macOS repeats into whatever comes forward
    /// next - the failure this whole epic exists to avoid. A button left down is a drag
    /// macOS continues across whatever the pointer crosses. The client cannot clean up
    /// after itself in precisely the case that matters, so vhidd does it, on every
    /// way a connection can end - and on its own way out, for the same reason. Each device
    /// is released whatever the other answered, and the lock is held across both: a
    /// report landing between them would be a key set down after the keyboard was cleared,
    /// with nothing left to catch it.
    func releaseEverything(because reason: String) {
        device.lock()
        defer { device.unlock() }
        let key = outcome(of: keyboard.releaseAll)
        log(key.map { "\(reason), and the keyboard would not release: \($0)" } ?? "\(reason); every key is up")
        let button = outcome(of: mouse.releaseAll)
        log(button.map { "\(reason), and the mouse would not release: \($0)" } ?? "\(reason); every button is up")
    }

    /// [LAW:parse-dont-validate] The wire is wider than the device on every count - a usage
    /// outside the keyboard page's keys names no key, button 0 and 33 upward have no bit,
    /// and -128 is below the descriptor's minimum -
    /// and a value the device cannot carry is refused here by name, once, rather than
    /// folded to the nearest one it can.
    private static func usage(_ value: UInt16) throws -> Usage {
        guard Usage.keys.contains(value) else { throw NotOnTheDevice.usage(value) }
        return Usage(rawValue: value)
    }

    private static func button(_ number: UInt8) throws -> Button {
        guard let button = Button(rawValue: number) else { throw NotOnTheDevice.button(number) }
        return button
    }

    private static func count(_ value: Int8) throws -> Count {
        guard let count = Count(exactly: value) else { throw NotOnTheDevice.count(value) }
        return count
    }
}

/// A value the wire can carry and the device cannot.
enum NotOnTheDevice: Error, CustomStringConvertible {
    case usage(UInt16)
    case button(UInt8)
    case count(Int8)

    var description: String {
        switch self {
        case .usage(let value): "usage \(value) is not one of the keys \(Usage.keys.lowerBound) through \(Usage.keys.upperBound)"
        case .button(let number): "button \(number) is not one of the 32 the device has a bit for"
        case .count(let value): "\(value) is outside the -127 through 127 a report carries"
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
func refusal(_ error: any Error) -> NSError {
    let code = switch error {
    case is Readiness.Down: Installation.devicesDownCode
    case is Holder.Busy, is Seat.Ended, is Seat.Lost: Installation.seatRefusedCode
    default: 1
    }
    return NSError(domain: Installation.refusalDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
}
