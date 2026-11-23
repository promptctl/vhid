/// What a device may be holding, kept by how each report to it ended.
///
/// [LAW:one-type-per-behavior] Keys and buttons follow one rule, so it is written once:
/// - A report never sent leaves the record as it was: the driver did not see it.
/// - One that may have reached the driver widens what may be held by what it asked for,
///   since the driver may hold the old set or the new.
/// - An answer settles the record to what was sent, since a report is the whole set.
///
/// The next report is built from `asked`, what the driver was last asked to hold, never
/// from what may be held: a key an unanswered report may have left down is one for a
/// release to lift, and not one for the next press to hold again.
struct Held<Part: Hashable & Sendable>: Sendable {
    /// What the last report that may have reached the driver asked it to hold.
    private(set) var asked: Set<Part> = []
    /// What the driver may be holding: what it was asked to, and whatever a report it did
    /// not answer asked for besides. It may say a part is held that is not; it may never
    /// say a part is up that is, because a part it has forgotten is one nothing will lift.
    private(set) var mayBe: Set<Part> = []
    /// Whether the driver answered the report of `asked`.
    private(set) var settled = false

    /// Sends the report of `sent` and keeps the record by how it ended.
    mutating func report(_ sent: Set<Part>, _ send: () throws(Unanswered) -> Void) throws(Unanswered) {
        do {
            try send()
            (asked, mayBe, settled) = (sent, sent, true)
        } catch {
            if error.mayHaveReachedTheDriver {
                (asked, settled) = (sent, false)
                mayBe.formUnion(sent)
            }
            throw error
        }
    }
}
