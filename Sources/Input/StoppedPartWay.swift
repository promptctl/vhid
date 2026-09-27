/// A run that stopped because something else failed under it, carrying that failure.
///
/// Each layer that stops a run wraps what stopped it with what only that layer knows - how
/// many characters landed, which actions were done - so the failure a caller has to act on
/// sits several causes down. [LAW:locality-or-seam] Each wrapper declares this beside its
/// `cause`, in place of `Error`, so a new wrapper is marked where it is written; one left
/// unmarked hides everything under it from `causes`, as `PointingStopped` once did.
public protocol StoppedPartWay: Error {
    var cause: any Error { get }
}

public extension Error {
    /// This error and every cause under it, outermost first.
    var causes: [any Error] {
        Array(sequence(first: self as any Error) { ($0 as? any StoppedPartWay)?.cause })
    }

    /// What a report calls this failure.
    ///
    /// Every failure here says what it is, except the one the language supplies:
    /// `CancellationError` has no description of its own, so interpolating it prints
    /// `CancellationError()` at the front of a sentence an operator reads. It is the one
    /// stop that is not a failure at all - the caller asked for it - so it is named as the
    /// thing that happened. [LAW:comments-carry-meaning]
    ///
    /// This is the one place that translation happens, so a cancelled typing run, chord,
    /// click and replay all report it the same way. [LAW:one-source-of-truth]
    var reported: String {
        self is CancellationError ? "the run was cancelled" : "\(self)"
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
