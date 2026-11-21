/// Work that must never overlap, run one piece after another.
///
/// **Not the order it was handed in.** A turn is taken when its caller reaches this actor,
/// and callers in tasks of their own race here, so two handed in together can take their
/// turns either way round. A caller that needs one piece after another waits for the first
/// one's answer. [LAW:no-ambient-temporal-coupling] Exclusion is this actor's to own; order
/// is the caller's.
public actor Turns {
    private var last: Task<Void, Never>?

    public init() {}

    /// Runs `work` once every piece that took its turn before this one has finished. A
    /// cancelled caller cancels its work, waiting or running.
    public func take<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let before = last
        // A caller cancelled before its turn is taken never starts its work: the turn's task
        // is its own, and the cancel would reach it only after it had begun.
        try Task.checkCancellation()
        let turn = Task {
            await before?.value
            try Task.checkCancellation()
            return try await work()
        }
        last = Task { _ = await turn.result }
        return try await withTaskCancellationHandler { try await turn.value } onCancel: { turn.cancel() }
    }
}
