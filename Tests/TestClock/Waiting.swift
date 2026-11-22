import Foundation
import Testing
import Time

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

/// A gate the code under test blocks at until the test opens it, as a latch is a gate in
/// Goetz's *Java Concurrency in Practice*; `arrived` opens as it gets there, so the test
/// knows it is blocked before it moves on.
public final class Gate: Sendable {
    public let arrived = Latch()
    private let opened = Latch()

    public init() {}

    /// Called by the code under test at the gate: blocks until the test opens it.
    public func arrive() {
        arrived.open()
        opened.wait("the test to open the gate")
    }

    public func open() { opened.open() }
}

/// A value under a lock, changed by the code under test and waited on by the test until it
/// says what the test is waiting for: no poll and no sleep, and a wait that never ends is a
/// recorded hang after `hangGuard`.
public final class Watched<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// Changes the value, or reads it, and wakes every wait to look again.
    @discardableResult
    public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        return try body(&value)
    }

    public var current: Value { withLock { $0 } }

    /// Waits until `holds` is true of the value, answering whether it came to be.
    @discardableResult
    public func wait(_ what: String, until holds: (Value) -> Bool, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let giveUp = Date(timeIntervalSinceNow: hangGuard.seconds)
        condition.lock()
        defer { condition.unlock() }
        while !holds(value) {
            guard condition.wait(until: giveUp) || holds(value) else {
                Issue.record("\(what) had not come \(hangGuard) later", sourceLocation: sourceLocation)
                return false
            }
        }
        return true
    }
}

/// A call that blocks until the test moves its clock or lets a fake go, run on a thread of
/// its own, as the code under test is run in the product, and waited for once the test has.
public final class Pending<T>: Sendable {
    private let ended = Watched<Result<T, any Error>?>(nil)

    public init(_ call: @escaping @Sendable () throws -> T) {
        Thread.detachNewThread { [ended] in
            let result = Result { try call() }
            ended.withLock { $0 = result }
        }
    }

    /// What the call returned, or what it threw, once it has; a call that never ends is a
    /// recorded hang, thrown as `Hung`.
    public func get(sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
        guard ended.wait("the call to end", until: { $0 != nil }, sourceLocation: sourceLocation), let result = ended.current else { throw Hung() }
        return try result.get()
    }

    public struct Hung: Error {}
}

/// A named pipe a child process writes to say it has reached a point - started, wrote its
/// pid - which the test reads to know it has, with no poll and no sleep.
public final class Fifo: Sendable {
    public let path: String

    public init() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "fifo-\(UUID().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    deinit { unlink(path) }

    /// What the next writer wrote, once it closes the pipe, or nil after `hangGuard`. The
    /// blocking open and read are on a thread of their own, so a writer that never comes
    /// is a recorded hang and not a test that never ends.
    public func said(sourceLocation: SourceLocation = #_sourceLocation) -> String? {
        let heard = Latch(), path = path
        nonisolated(unsafe) var said: String?
        Thread.detachNewThread {
            said = FileHandle(forReadingAtPath: path).map { String(decoding: $0.readDataToEndOfFile(), as: UTF8.self) }
            heard.open()
        }
        guard heard.wait("a writer to \(path)", sourceLocation: sourceLocation) else { return nil }
        return said?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes a line to the next reader, for a child waiting on the test: on a thread of its
    /// own, for the reason `said` reads on one.
    public func say(_ line: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        let written = Latch(), path = path
        Thread.detachNewThread {
            FileHandle(forWritingAtPath: path)?.write(Data("\(line)\n".utf8))
            written.open()
        }
        written.wait("a reader of \(path)", sourceLocation: sourceLocation)
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
