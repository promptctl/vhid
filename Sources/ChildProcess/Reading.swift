import Foundation
import Telemetry
import Time

/// Takes a reading of this Mac that blocks on the commands it runs, within `limit` counted
/// from this call, and ends the command running when the task is cancelled: Control-C or
/// SIGTERM on the command line, a withdrawn call over MCP.
///
/// [LAW:no-ambient-temporal-coupling] The deadline is made here, where the reading is asked,
/// and handed to `read`, so the wait for a thread to read on is counted against the limit
/// too: a command still queued when the limit passes is not started. On a serial queue of the
/// reading's own and not on the cooperative pool, whose few threads the MCP server's
/// transport runs on too, nor on `DispatchQueue.global()`, whose bounded pool a busy process
/// fills: dispatch gives a queue of its own a thread whenever it has work.
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
public func reading<T: Sendable>(within limit: Duration, on timeline: Timeline, _ read: @escaping @Sendable (Deadline, Command.Stop) -> T) async throws(CancellationError) -> T {
    try await reading(by: .within(limit, on: timeline), on: DispatchQueue(label: "ChildProcess.reading"), read)
}

/// The reading by a deadline already made, on `queue`, which a test holds to show the wait
/// for it is counted.
func reading<T: Sendable>(by deadline: Deadline, on queue: DispatchQueue, _ read: @escaping @Sendable (Deadline, Command.Stop) -> T) async throws(CancellationError) -> T {
    let stop = Command.Stop()
    let taken = await withTaskCancellationHandler {
        await withCheckedContinuation { reading in
            queue.async { reading.resume(returning: read(deadline, stop)) }
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
