/// What a device is holding, kept by how far each report that changed it got.
///
/// `down` may say something is held that is not; it may never say something is up that
/// is held, because a key or a button the record has already forgotten is one a release
/// cannot get back up, and macOS repeats the key or carries the drag on. So a report the
/// daemon did not answer is read by whether any of it may have reached the driver: one
/// that may have leaves both the old set and the new one recorded, since the driver may
/// hold either; one that never left this side changed nothing, and the record stays as
/// it was. An answer settles the record to exactly what was sent.
///
/// [LAW:single-enforcer] The one rule for both devices: a keyboard and a mouse that kept
/// it apart could keep it two ways.
struct Held<Element: Hashable> {
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
                down.formUnion(next)
                settled = false
            }
            throw error.reason
        }
        down = next
        settled = true
    }
}
