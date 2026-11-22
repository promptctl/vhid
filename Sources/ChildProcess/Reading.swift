import Foundation
import Telemetry

/// Takes a reading of this Mac within `limit`, one that blocks on the commands it runs,
/// and ends the command running when the task is cancelled: Control-C or SIGTERM on the
/// command line, a withdrawn call over MCP. What the reading waits on besides commands, as
/// doctor waits on the daemon's status reply, is not ended: it is bounded by what the
/// deadline has `left`.
///
/// [LAW:no-ambient-temporal-coupling] The deadline is made here, at the call, before the
/// reading waits for a thread, so the limit and the cancel count from the moment the
/// caller asked, however busy the Mac is. `read` is handed that deadline for every command
/// it runs.
///
/// On `queue`, by default a serial queue of its own: not the cooperative pool, whose few
/// threads the MCP server's transport runs on too, and not `DispatchQueue.global()`, which
/// is capped near the core count and holds work back while other blocked work fills it. A
/// queue of its own draws on dispatch's overcommit pool, which gives it a thread however
/// many others are blocked - the same move `DeviceQueue` makes for the device calls. A
/// queue held busy is what a busy Mac does to a reading, so a test hands in one it holds.
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
    on queue: DispatchQueue = DispatchQueue(label: "ChildProcess.reading"),
    _ read: @escaping @Sendable (Command.Deadline) -> T
) async throws(CancellationError) -> T {
    let deadline = Command.Deadline.within(limit)
    let taken = await withTaskCancellationHandler {
        await withCheckedContinuation { reading in
            queue.async { reading.resume(returning: read(deadline)) }
        }
    } onCancel: {
        deadline.stop.pull()
    }
    if Task.isCancelled {
        Telemetry.note(.stopped, .array(deadline.stop.ended.map(JSON.string)))
        throw CancellationError()
    }
    return taken
}
