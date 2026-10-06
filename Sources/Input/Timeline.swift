/// A clock as offsets from when it was made: what time it is, and a sleep until a given
/// one. A move's deadlines and a typist's keys are offsets from their start, so this is all
/// of a clock a pointer or a typist needs, and it keeps them free of the clock's type.
public struct Timeline: Sendable {
    public let now: @Sendable () -> Duration
    public let sleep: @Sendable (_ until: Duration) async throws -> Void

    public init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(until: origin.advanced(by: $0), tolerance: .zero) }
    }

    /// A sleep until `due` that hands `slept` how long it slept once it ends, however it
    /// ends: one a cancel cut short says how long it got. [LAW:single-enforcer] Every wait a
    /// pointer or a typist makes between its reports is one of these, so every one is traced.
    func pause(until due: Duration, slept: (Duration) -> Void) async throws {
        let began = now()
        defer { slept(max(now() - began, .zero)) }
        try await sleep(due)
    }
}
