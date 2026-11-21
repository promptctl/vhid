import Telemetry

/// A run that stopped because something else failed under it, carrying that failure.
///
/// Each layer that stops a run wraps what stopped it with what only that layer knows - how
/// many characters landed, which actions were done - so the failure a caller has to act on
/// sits several causes down. [LAW:locality-or-seam] Each wrapper declares this beside its
/// `cause`, in place of `Error`, so a new wrapper is marked where it is written; one left
/// unmarked hides everything under it from `causes`, as `PointingStopped` once did. The
/// chain is Telemetry's, so a record reads a cancellation the way a caller does.
public protocol StoppedPartWay: Caused {}

/// What `release` threw, answered rather than thrown: every run that stops lets its device
/// go on the way out and reports a release that failed beside the stop, never over it, so
/// the operator is told both. [LAW:no-silent-failure] The one way a release is caught,
/// for the keyboard and the mouse alike; each device says what was left held in its own
/// words. [LAW:one-source-of-truth]
func failure(of release: () async throws -> Void, isolation: isolated (any Actor)? = #isolation) async -> (any Error)? {
    do {
        try await release()
        return nil
    } catch {
        return error
    }
}

public extension String {
    /// This report with `next` after it as a sentence of its own.
    ///
    /// Every wrapper that says more after its cause joins them here, so none has to know
    /// what the cause ends on. [LAW:one-source-of-truth] A cause that already ends a
    /// sentence gets no second full stop, and one over several lines - the daemon's
    /// refusal ends on the driver's step, sometimes on a command to copy - has `next` on a
    /// line of its own, where it is not read as part of that step or pasted with it.
    func then(_ next: String) -> String {
        if contains("\n") { return "\(self)\n\(next)" }
        return hasSuffix(".") ? "\(self) \(next)" : "\(self). \(next)"
    }
}
