/// A clock as offsets from when it was made: what time it is, and a sleep until a given
/// one. A move's deadlines, a typist's keys, a request's limit and a daemon's retries are
/// offsets from their start, so this is all of a clock any of them needs, and it keeps them
/// free of the clock's type: the real one in use, and a test's hand-moved one in a test.
/// [LAW:one-type-per-behavior]
public struct Timeline: Sendable {
    public let now: @Sendable () -> Duration
    public let sleep: @Sendable (_ until: Duration) async throws -> Void

    public init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(until: origin.advanced(by: $0), tolerance: .zero) }
    }
}
