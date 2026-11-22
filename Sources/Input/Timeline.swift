import Timeline

extension Timeline {
    /// A sleep until `due` that hands `slept` how long it slept once it ends, however it
    /// ends: one a cancel cut short says how long it got. [LAW:single-enforcer] Every wait a
    /// pointer or a typist makes between its reports is one of these, so every one is traced.
    func pause(until due: Duration, slept: (Duration) -> Void) async throws {
        let began = now()
        defer { slept(max(now() - began, .zero)) }
        try await sleep(due)
    }
}
