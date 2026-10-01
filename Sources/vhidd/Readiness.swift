import DriverExtension
import Foundation

/// Whether the devices are up, and the devices when they are: what every seat asks before
/// it acts, and what the bring-up loop tells as it goes.
///
/// A daemon that cannot bring the devices up used to exit, and launchd started it again,
/// so the reason lived only in a log nobody reading a client's error would think to look
/// in. Now the reason is the answer every act gets from a listener that is already up.
/// [LAW:no-silent-failure]
///
/// [LAW:parse-dont-validate] `devices()` is the one crossing: it hands back devices that
/// are up or throws why not, so a seat asks before it claims the holder, and a client
/// turned away while the devices are down holds nothing.
final class Readiness: @unchecked Sendable {
    /// Why the devices are not up, as the bring-up loop tells it.
    enum Down: CustomStringConvertible {
        /// The first attempt has not finished.
        case starting
        /// The last attempt failed, or the devices it brought up were lost, and another is
        /// scheduled.
        case failed(any Error)

        var description: String {
            switch self {
            case .starting: "devices not up: vhidd is still bringing them up"
            case .failed(let error): "devices not up: \(error)"
            }
        }
    }

    /// What a client whose act is refused is told: why the devices are not up, and the
    /// driver extension as it read for this refusal, or why it could not be read.
    ///
    /// pqrs's status says only "not activated" for an extension awaiting approval, one
    /// whose activation never landed and one half removed alike, so the state read on
    /// this Mac is what tells which step is the one: a person who skipped the installer's
    /// last page learns it from their first refused call. The driver is what that person
    /// changes while vhidd waits, so it is read for each refusal and kept nowhere: the
    /// step named is never one already done. [LAW:one-source-of-truth] with `vhid doctor`.
    struct Refused: Error, CustomStringConvertible {
        let why: Down
        let driver: Result<DriverState, any Error>

        /// A driver that is on has no step and adds nothing. One that could not be read
        /// is said so here, to the person who would otherwise be left without a step and
        /// without the reason. [LAW:no-silent-failure]
        var description: String {
            switch driver {
            case .success(let state):
                "\(why)" + (state.step.map { "\nThe driver extension reads \(state.rawValue):\n\($0)" } ?? "")
            case .failure(let error):
                "\(why)\nThe driver extension could not be read: \(error)"
            }
        }
    }

    /// [LAW:types-are-the-program] Down carries why and up carries the devices: an act is
    /// either refused with a reason or served.
    private enum State {
        case down(Down)
        case up(Up)
    }

    /// Devices that are up, and the attempt that brought them up: devices from two
    /// attempts are two sets, and what a client held on the first is gone from the second.
    struct Up {
        let devices: any ServedDevices
        let attempt: Int
    }

    /// Its own lock and never the devices', so a refusal waits on no attempt, however long
    /// one is taking. A condition, because the bring-up loop waits on it for the devices
    /// to be lost. [LAW:no-shared-mutable-globals]
    private let condition = NSCondition()
    private var state = State.down(.starting)
    /// Counts attempts, so a connection is known by the attempt that opened it.
    private var attempt = 0
    /// How the current attempt ended, if it has: at most one ending each, so a loss
    /// reported late by an attempt that already failed cannot replace why it failed, and
    /// devices whose connection went before they were handed over are not handed over.
    private var ended = false
    /// How long a reading of the driver is given. A client refused is answered after the
    /// reading, and waits `HelperConnection.replyTimeout` for the answer: a reading that
    /// cannot be taken is given up on while that client is still listening.
    static let driverReadLimit: Duration = .seconds(2)

    /// Reads the driver extension on this Mac.
    private let driver: () throws -> DriverState

    init(driver: @escaping () throws -> DriverState) {
        self.driver = driver
    }

    private var current: State {
        condition.lock(); defer { condition.unlock() }
        return state
    }

    /// The devices, or the refusal a client is told. The driver is read outside the lock,
    /// so one client's refusal holds up nobody else's act.
    func devices() throws -> Up {
        switch current {
        case .down(let why): throw Refused(why: why, driver: Result { try driver() })
        case .up(let up): return up
        }
    }

    /// The devices when they are up, for work that is only ever done on devices that are:
    /// nobody is refused, so the driver is not read.
    var up: Up? {
        switch current {
        case .down: nil
        case .up(let up): up
        }
    }

    /// Devices that are not up hold nothing, so there is nothing to release.
    func releaseEverything(because reason: String) {
        switch current {
        case .down(let why): log("\(reason); nothing is held: \(why)")
        case .up(let up): up.devices.releaseEverything(because: reason)
        }
    }

    /// Starts an attempt, returning the number its connection's loss is reported under.
    func begin() -> Int {
        condition.lock(); defer { condition.unlock() }
        attempt += 1
        ended = false
        return attempt
    }

    func failed(_ error: any Error) {
        condition.lock(); defer { condition.unlock() }
        guard !ended else { return }
        ended = true
        state = .down(.failed(error))
    }

    /// Serves `devices` from the next act on, unless the current attempt's connection was
    /// lost before they were handed over, in which case they stay down on that loss.
    func up(_ devices: any ServedDevices) {
        condition.lock(); defer { condition.unlock() }
        guard !ended else { return }
        state = .up(Up(devices: devices, attempt: attempt))
    }

    /// Takes the devices down when `attempt` is the current one and has not already ended,
    /// and says whether it did.
    func lost(_ error: any Error, in attempt: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard attempt == self.attempt, !ended else { return false }
        ended = true
        state = .down(.failed(error))
        condition.broadcast()
        return true
    }

    /// Returns once the devices are down, with why.
    func whileUp() -> Down {
        condition.lock(); defer { condition.unlock() }
        while true {
            switch state {
            case .down(let why): return why
            case .up: condition.wait()
            }
        }
    }
}
