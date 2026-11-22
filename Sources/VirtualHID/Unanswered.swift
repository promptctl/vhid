import Time

/// A request the daemon did not answer: how far it got, which says whether the driver may
/// have it, and what ended the wait for its answer.
///
/// [LAW:types-are-the-program] Both halves, because every pairing of them happens and each
/// says something of its own. A request never written was not seen by the driver and never
/// will be, which is the one case a caller may report as a command that did not happen;
/// every other is a command whose outcome is unknown.
public struct Unanswered: Error, Equatable, CustomStringConvertible {
    public enum Reach: Equatable, Sendable {
        /// Never written: it waited in the write queue behind other frames until the wait
        /// ended.
        case unsent
        /// Being written: the writer had taken it, and the socket had not taken all of it.
        case writing
        /// Written whole, and not answered.
        case written
    }

    public enum Cause: Equatable, Sendable {
        /// Its deadline passed.
        case deadline(Deadline.Passed)
        /// The connection ended.
        case connection(DaemonError)
    }

    public let reach: Reach
    public let cause: Cause

    public init(reach: Reach, cause: Cause) {
        self.reach = reach
        self.cause = cause
    }

    /// Whether the driver may hold what the request asked for, then or later.
    /// [LAW:single-enforcer] The one reading of `reach` that a record and a caller decide by.
    public var mayHaveReachedTheDriver: Bool { reach != .unsent }

    public var description: String {
        switch (reach, cause) {
        case (.unsent, .connection(let lost)):
            "\(lost), and the request was not sent"
        case (.unsent, .deadline(let passed)):
            "the request was not sent: its limit of \(passed.limit) had passed while it waited in the write queue for the driver's daemon's socket"
        case (.writing, .deadline(let passed)):
            "the driver's daemon had not taken the whole request when its limit of \(passed.limit) passed; the rest is still going, and the driver may yet act on it"
        case (.written, .deadline(let passed)):
            "the driver's daemon did not answer within the limit of \(passed.limit); the driver may have acted on the request"
        case (_, .connection(let lost)):
            "\(lost) before answering; the driver may have acted on the request"
        }
    }
}
