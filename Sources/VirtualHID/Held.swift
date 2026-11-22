import Timeline

/// What a device is holding, kept by how far each report that changed it got, as two sets
/// with two jobs.
///
/// `asked` is what the last report that left this side asked the driver to hold, whatever
/// came of it: what the next report is built from. A report never sent asked nothing. A report that went unanswered is not taken back by the
/// next one, and a release that went unanswered is not undone by a move that carries the
/// buttons it let go of.
///
/// `down` is what the driver may be holding: what a release must clear. It may say
/// something is held that is not; it may never say something is up that is held, because
/// a key or a button the record has already forgotten is one a release cannot get back up,
/// and macOS repeats the key or carries the drag on. So a report the daemon did not answer
/// is read by whether any of it may have reached the driver: one that may have leaves both
/// the old set and the new one in `down`, since the driver may hold either; one that never
/// left this side leaves `down` as it was. An answer settles both to exactly what was sent,
/// since a report is the whole of what the device holds.
///
/// [LAW:one-source-of-truth] Two sets because they are two facts: what was asked for and
/// what may have happened part way to it.
struct Held<Element: Hashable> {
    private(set) var asked: Set<Element> = []
    private(set) var down: Set<Element> = []
    /// Whether the driver acknowledged exactly `down`: false whenever a report that may
    /// have reached it went unanswered.
    private(set) var settled = false

    /// Sends what makes `next` the set held, by `send`, and keeps the record by its outcome.
    /// [LAW:dataflow-not-control-flow]
    mutating func post(_ next: Set<Element>, by send: () throws(DaemonConnection.Unanswered) -> Void) throws(DaemonError) {
        do {
            try send()
        } catch {
            if error.mayHaveReached {
                asked = next
                down.formUnion(next)
                settled = false
            }
            throw error.reason
        }
        asked = next
        down = next
        settled = true
    }
}

/// A device on the daemon's connection and the record of what it holds: every report it
/// posts is built from that record, under a lock taken by the report's deadline and held
/// across the round trip, and the record is kept by `Held`'s rule.
///
/// [LAW:one-type-per-behavior] The keyboard and the mouse differ only in their requests and
/// in how a report is laid out, so they are one device given those, and the locking, the
/// reset and the record are written once.
///
/// The lock is held across the round trip: a change read from a record another post has
/// yet to settle would be a report missing that post's key, which the driver reads as a
/// release nobody sent. Taken by the report's deadline, so a caller of either device waits
/// its turn by its own limit and is never queued past it. [LAW:single-enforcer]
final class HeldDevice<Element: Hashable & Sendable>: @unchecked Sendable {
    private let daemon: DaemonConnection
    private let report: DaemonConnection.Request
    private let resetting: DaemonConnection.Request
    private let lock = TimedLock()
    /// Under `lock`. [LAW:no-shared-mutable-globals]
    private var held = Held<Element>()

    init(daemon: DaemonConnection, report: DaemonConnection.Request, reset: DaemonConnection.Request) {
        self.daemon = daemon
        self.report = report
        resetting = reset
    }

    /// What the driver may be holding, once any report in flight has had its answer.
    var down: Set<Element> { lock.withLock { held.down } }

    /// Posts the report `build` lays out for the set `change` makes of the record, by
    /// `deadline`, and keeps the record by how far it got. `change` answers nil when the
    /// record already says what it would post, and nothing is posted.
    ///
    /// The report is built before anything is sent, so a set the report cannot carry is
    /// this side refusing with nothing on the wire, and the record does not claim it.
    func post(by deadline: Deadline, _ change: (Held<Element>) -> Set<Element>?, laidOut build: (Set<Element>) throws -> [UInt8]) throws {
        try lock.withLock(by: deadline) {
            guard let next = change(held) else { return }
            let bytes = try build(next)
            try held.post(next) { () throws(DaemonConnection.Unanswered) in try daemon.request(report, bytes, by: deadline) }
        }
    }

    /// Clears the device's own state as well as this side's: what the daemon offers for the
    /// case where the two might have drifted apart. The record is kept by `Held`'s rule, as
    /// a report of nothing held is.
    func reset(by deadline: Deadline) throws {
        try lock.withLock(by: deadline) {
            try held.post([]) { () throws(DaemonConnection.Unanswered) in try daemon.request(resetting, by: deadline) }
        }
    }
}
