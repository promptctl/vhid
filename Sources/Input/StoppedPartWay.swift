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
