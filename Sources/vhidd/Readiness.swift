import DriverExtension
import Foundation

/// Whether the devices are up, and the devices when they are: what every seat asks before
/// it acts, and what the bring-up loop tells as it goes.
///
/// A daemon that cannot bring the devices up used to exit, and launchd started it again,
/// so the reason lived only in a log nobody reading a client's error would think to look
/// in. Now the reason is the answer every act gets, straight away, from a listener that is
/// already up. [LAW:no-silent-failure]
///
/// [LAW:parse-dont-validate] `devices()` is the one crossing: it hands back devices that
/// are up or throws why not, so a seat asks before it claims the holder, and a client
/// turned away while the devices are down holds nothing.
final class Readiness: @unchecked Sendable {
    /// Why the devices are not up, as a client is told it.
    enum Down: Error, CustomStringConvertible {
        /// The first attempt has not finished.
        case starting
        /// The last attempt failed, or the devices it brought up were lost, and another is
        /// scheduled. `driver` is the driver extension as last read since the attempt
        /// ended, or nil when it has not been read or could not be.
        ///
        /// pqrs's status says only "not activated" for an extension awaiting approval, one
        /// whose activation never landed and one half removed alike, so the state read on
        /// this Mac is what tells which step is the one: a person who skipped the
        /// installer's last page learns it from their first refused call. The reading is
        /// kept apart from the error because it is what the person changes while vhidd
        /// waits, and the step named is the one for the driver as it reads now.
        /// [LAW:one-source-of-truth] with `vhid doctor`.
        case failed(any Error, driver: DriverState?)

        /// Names no step when the driver is on or has no reading.
        var description: String {
            switch self {
            case .starting:
                "devices not up: vhidd is still bringing them up"
            case .failed(let error, let driver):
                "devices not up: \(error)" + (driver.flatMap { state in
                    state.step.map { "\nThe driver extension reads \(state.rawValue):\n\($0)" }
                } ?? "")
            }
        }
    }

    /// [LAW:types-are-the-program] Down carries why and up carries the devices: an act is
    /// either refused with a reason or served.
    private enum State {
        case down(Down)
        case up(Up)

        /// This state once the driver has been read as `driver`. Only an attempt that ended
        /// names the driver, so a reading changes nothing else: devices that are up are
        /// refused to nobody, and an attempt still starting has no failure to add a step to.
        func naming(_ driver: DriverState?) -> State {
            switch self {
            case .down(.failed(let error, _)): .down(.failed(error, driver: driver))
            case .down(.starting), .up: self
            }
        }
    }

    /// Devices that are up, and the attempt that brought them up: devices from two
    /// attempts are two sets, and what a client held on the first is gone from the second.
    struct Up {
        let devices: any ServedDevices
        let attempt: Int
    }

    /// Its own lock and never the devices', so a refusal is answered at once however long
    /// an attempt is taking. A condition, because the bring-up loop waits on it for the
    /// devices to be lost. [LAW:no-shared-mutable-globals]
    private let condition = NSCondition()
    private var state = State.down(.starting)
    /// Counts attempts, so a connection is known by the attempt that opened it.
    private var attempt = 0
    /// How the current attempt ended, if it has: at most one ending each, so a loss
    /// reported late by an attempt that already failed cannot replace why it failed, and
    /// devices whose connection went before they were handed over are not handed over.
    private var ended = false

    /// The devices, or why they are not up.
    func devices() throws -> Up {
        condition.lock(); defer { condition.unlock() }
        switch state {
        case .down(let why): throw why
        case .up(let up): return up
        }
    }

    /// Devices that are not up hold nothing, so there is nothing to release.
    func releaseEverything(because reason: String) {
        do {
            try devices().devices.releaseEverything(because: reason)
        } catch {
            log("\(reason); nothing is held: \(error)")
        }
    }

    /// Starts an attempt, returning the number its connection's loss is reported under.
    func begin() -> Int {
        condition.lock(); defer { condition.unlock() }
        attempt += 1
        ended = false
        return attempt
    }

    /// Ends the current attempt as failed with the driver as it read at the failure. An
    /// attempt that had already ended keeps its reason and takes the reading, which is
    /// newer than the one it had.
    func failed(_ error: any Error, driver: DriverState?) {
        condition.lock(); defer { condition.unlock() }
        state = ended ? state.naming(driver) : .down(.failed(error, driver: driver))
        ended = true
    }

    /// The driver as just read, which a refusal names from now until the next reading.
    func driver(reads driver: DriverState?) {
        condition.lock(); defer { condition.unlock() }
        state = state.naming(driver)
    }

    /// Serves `devices` from the next act on, unless the current attempt's connection was
    /// lost before they were handed over, in which case they stay down on that loss.
    func up(_ devices: any ServedDevices) {
        condition.lock(); defer { condition.unlock() }
        guard !ended else { return }
        state = .up(Up(devices: devices, attempt: attempt))
    }

    /// Takes the devices down when `attempt` is the current one and has not already ended,
    /// and says whether it did. The driver has not been read since, so no step is named
    /// until it is.
    func lost(_ error: any Error, in attempt: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard attempt == self.attempt, !ended else { return false }
        ended = true
        state = .down(.failed(error, driver: nil))
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
