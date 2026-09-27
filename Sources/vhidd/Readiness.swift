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
        /// scheduled.
        case failed(any Error)

        var description: String {
            switch self {
            case .starting: "devices not up: vhidd is still bringing them up"
            case .failed(let error): "devices not up: \(error)"
            }
        }
    }

    /// [LAW:types-are-the-program] Down carries why and up carries the devices: an act is
    /// either refused with a reason or served.
    private enum State {
        case down(Down)
        case up(any ServedDevices)
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
    func devices() throws -> any ServedDevices {
        condition.lock(); defer { condition.unlock() }
        switch state {
        case .down(let why): throw why
        case .up(let devices): return devices
        }
    }

    /// Devices that are not up hold nothing, so there is nothing to release.
    func releaseEverything(because reason: String) {
        do {
            try devices().releaseEverything(because: reason)
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

    func failed(_ error: any Error) {
        condition.lock(); defer { condition.unlock() }
        ended = true
        state = .down(.failed(error))
    }

    /// Serves `devices` from the next act on, unless the current attempt's connection was
    /// lost before they were handed over, in which case they stay down on that loss.
    func up(_ devices: any ServedDevices) {
        condition.lock(); defer { condition.unlock() }
        guard !ended else { return }
        state = .up(devices)
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
