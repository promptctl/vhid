import Foundation
import Testing

/// How long of real time a test waits for something that will come before it records the
/// wait as a hang. Never a measurement: an event a test is sure of arrives in microseconds
/// on an idle Mac and in seconds on a loaded one, and either way well inside this, so a
/// test that passes does not depend on how fast the machine ran it, and one that hangs
/// ends, failed, instead of holding the suite. [LAW:no-ambient-temporal-coupling]
public let hangGuard: Duration = .seconds(30)

/// Waits on `semaphore` for something sure to come, recording a hang when `hangGuard` ends
/// the wait first. Answers whether it came.
@discardableResult
public func guarded(_ semaphore: DispatchSemaphore, _ what: String = "an event sure to come", sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
    let came = semaphore.wait(timeout: .now() + .nanoseconds(Int(hangGuard.components.seconds) * 1_000_000_000)) == .success
    if !came { Issue.record("\(what) had not come \(hangGuard) later", sourceLocation: sourceLocation) }
    return came
}

/// A one-way gate a test opens once: whatever waits on it is held until then.
public final class Latch: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    public init() {}

    public func open() { semaphore.signal() }

    /// Waits for the latch to open, for at most `hangGuard`. A latch is opened once and
    /// waited on once.
    @discardableResult
    public func wait(_ what: String = "a latch to open", sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guarded(semaphore, what, sourceLocation: sourceLocation)
    }
}

/// Two latches in a row, for a fake that stands at a step: the code under test says it has
/// reached the step, and waits there until the test lets it go.
public final class Handshake: Sendable {
    public let reached = Latch()
    public let released = Latch()

    public init() {}

    /// Called by the code under test at the step.
    public func arrive() {
        reached.open()
        released.wait("the test to let the step go")
    }
}

/// Yields until `condition` holds, for a test that needs a task it cannot join to reach a
/// point first, failing as a hang after `hangGuard`. Only for a state the test has no event
/// to wait on: every wait with an event takes a latch.
public func yielding(until condition: () -> Bool, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    let started = ContinuousClock.now
    while !condition() {
        guard ContinuousClock.now - started < hangGuard else {
            Issue.record("\(what) had not happened \(hangGuard) later", sourceLocation: sourceLocation)
            return
        }
        await Task.yield()
    }
}
