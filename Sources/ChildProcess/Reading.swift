import Foundation
import Telemetry

/// Takes a reading of this Mac that blocks on the commands it runs, and ends the command
/// running when the task is cancelled: Control-C or SIGTERM on the command line, a
/// withdrawn call over MCP. What the reading waits on besides commands, as doctor waits on
/// the daemon's status reply, is not ended: its own timeout bounds it.
///
/// On a queue of its own, as `DeviceQueue` runs the device calls: off the cooperative
/// pool, whose few threads the MCP server's transport runs on too, and off the pool
/// behind `DispatchQueue.global()`, which starts no thread while this process keeps a
/// thread busy for each core. Every limit a reading runs to is made once the reading
/// starts, so a reading that waited for a thread would wait past its limit: on CI one
/// given 200 ms waited 14 s behind the suites that were using every core. A queue made
/// for the one reading is given a thread at once. [LAW:no-ambient-temporal-coupling]
///
/// [LAW:single-enforcer] The one place a cancel becomes a pulled `Command.Stop`, which
/// ends the command running - stopped and collected, as one given up on at its limit is -
/// and starts none after it. Throws only the cancellation: a reading that
/// could fail says so in what `read` returns, so a verb's own handling of that failure
/// can never take a cancel for one. [LAW:types-are-the-program] A reading the cancel cut
/// short is not an answer, and is not returned as one.
///
/// [LAW:nothing-unseen] A cancelled reading's record names the commands the cancel
/// ended: what a person who pressed Control-C was waiting on.
public func reading<T: Sendable>(_ read: @escaping @Sendable (Command.Stop) -> T) async throws(CancellationError) -> T {
    let stop = Command.Stop()
    let taken = await withTaskCancellationHandler {
        await withCheckedContinuation { reading in
            DispatchQueue(label: "ChildProcess.reading").async { reading.resume(returning: read(stop)) }
        }
    } onCancel: {
        stop.pull()
    }
    if Task.isCancelled {
        Telemetry.note(.stopped, .array(stop.ended.map(JSON.string)))
        throw CancellationError()
    }
    return taken
}
