import Foundation

/// The devices as served while vhidd is bringing them up: refused by reason until they
/// are up, and served as they are from then on.
///
/// A daemon that cannot bring the devices up used to exit, and launchd started it again,
/// so the reason lived only in a log nobody reading a client's error would think to look
/// in. Now the reason is the answer every act gets, straight away, from a listener that is
/// already up. [LAW:no-silent-failure]
///
/// [LAW:types-are-the-program] Down carries why, up carries the devices, and there is no
/// third state: an act is either refused with a reason or served.
final class Readiness: NSObject, ServedDevices, @unchecked Sendable {
    enum State {
        case down(Down)
        case up(any ServedDevices, daemon: DaemonProcess.Origin)
    }

    /// Why the devices are not up, as a client is told it.
    enum Down: Error, CustomStringConvertible {
        /// The first attempt has not finished.
        case starting
        /// The last attempt failed, and another is scheduled.
        case failed(any Error)

        var description: String {
            switch self {
            case .starting: "devices not up: vhidd is still bringing them up"
            case .failed(let error): "devices not up: \(error)"
            }
        }
    }

    /// Under its own lock and never the devices', so a refusal is answered at once however
    /// long an attempt at bringing them up is taking. [LAW:no-shared-mutable-globals]
    private let lock = NSLock()
    private var state = State.down(.starting)

    func become(_ next: State) {
        lock.lock(); defer { lock.unlock() }
        state = next
    }

    private var current: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// [LAW:dataflow-not-control-flow] Every act is the same act: the devices when they are
    /// up, the reason when they are not.
    private func serve(_ reply: @escaping (Error?) -> Void, _ act: (any ServedDevices) -> Void) {
        switch current {
        case .down(let why): reply(refusal(why))
        case .up(let devices, _): act(devices)
        }
    }

    func down(usage: UInt16, reply: @escaping (Error?) -> Void) { serve(reply) { $0.down(usage: usage, reply: reply) } }
    func releaseAll(reply: @escaping (Error?) -> Void) { serve(reply) { $0.releaseAll(reply: reply) } }
    func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { serve(reply) { $0.buttonDown(button, reply: reply) } }
    func releaseButtons(reply: @escaping (Error?) -> Void) { serve(reply) { $0.releaseButtons(reply: reply) } }
    func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { serve(reply) { $0.move(x: x, y: y, reply: reply) } }
    func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) {
        serve(reply) { $0.scroll(vertical: vertical, horizontal: horizontal, reply: reply) }
    }

    /// Devices that are not up hold nothing, so there is nothing to release.
    func releaseEverything(because reason: String) {
        switch current {
        case .down(let why): log("\(reason); nothing is held: \(why)")
        case .up(let devices, _): devices.releaseEverything(because: reason)
        }
    }

    /// Stops the daemon behind the devices when vhidd started it. Devices that are not up
    /// have no daemon of vhidd's behind them: an attempt that fails stops what it started
    /// before it says so.
    func stop<Device>(with effects: DaemonProcess.Effects<Device>) {
        switch current {
        case .down: log("no daemon of this helper's is running")
        case .up(_, let daemon): effects.stop(daemon)
        }
    }
}
