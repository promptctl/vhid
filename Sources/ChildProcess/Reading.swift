import Foundation
import Telemetry
import Timeline

/// Takes a reading of this Mac that blocks on the commands it runs, all of them over by
/// `limit` from this call, and ends the command running when the task is cancelled:
/// Control-C or SIGTERM on the command line, a withdrawn call over MCP.
///
/// [LAW:no-ambient-temporal-coupling] The deadline is made here, as the caller asks, and
/// not where `read` starts: the wait for a thread to run it on is the caller's wait too,
/// and a deadline made once that wait was over would leave it uncounted - measured, a
/// 200 ms limit that took 14 s on a runner whose cores were all busy.
///
/// On a serial queue made for this reading, and not on the cooperative pool, whose few
/// threads the MCP server's transport runs on too, nor on `DispatchQueue.global()`, which
/// adds a thread only while fewer than the cores are runnable: a queue of its own is given
/// a thread whenever it has work, however many others are blocked.
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
public func reading<T: Sendable>(
    within limit: Duration,
    on timeline: Timeline,
    _ read: @escaping @Sendable (Deadline, Command.Stop) -> T
) async throws(CancellationError) -> T {
    try await reading(within: limit, on: timeline, enqueue: { DispatchQueue(label: "reading").async(execute: $0) }, read)
}

/// The reading with its work handed to `enqueue`, which a test holds on to for as long as
/// it likes the wait for a thread to be.
func reading<T: Sendable>(
    within limit: Duration,
    on timeline: Timeline,
    enqueue: (@escaping @Sendable () -> Void) -> Void,
    _ read: @escaping @Sendable (Deadline, Command.Stop) -> T
) async throws(CancellationError) -> T {
    let deadline = timeline.deadline(within: limit)
    let stop = Command.Stop()
    let taken = await withTaskCancellationHandler {
        await withCheckedContinuation { reading in
            enqueue { reading.resume(returning: read(deadline, stop)) }
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
