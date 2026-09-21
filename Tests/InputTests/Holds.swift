/// Whether `condition` comes to hold within `window`, asked every `poll`: true the
/// moment it holds, false once the window has passed with it still not holding. The
/// last ask comes after the window closes, so a change on its final tick counts.
///
/// Test support, and it stays here rather than in the library: nothing vhid ships polls
/// for anything, and a helper exported for tests is a helper callers start using.
/// [LAW:decomposition]
///
/// [LAW:effects-at-boundaries] The condition is the caller's and is asked on the
/// caller's actor; this owns only the asking and the clock.
func holds(
    within window: Duration,
    askingEvery poll: Duration,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: window)
    while try !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await ContinuousClock().sleep(until: ContinuousClock.now.advanced(by: poll), tolerance: nil)
    }
    return true
}
