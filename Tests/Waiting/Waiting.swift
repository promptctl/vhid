import Foundation
import Testing
import Timeline

/// How long a test waits for an event that will come: far past any runner, however loaded,
/// and still an end, so a test whose event never comes fails by name instead of holding its
/// thread for good.
///
/// [LAW:single-enforcer] The one bound on such a wait. A wait bounded by a number of its own
/// is a wait whose verdict is the machine's speed: the number is a guess at how long the
/// event takes, and a busy runner outguesses it. A limit *under test* is never this: it is
/// given to a peer that cannot answer, so its verdict is the same at any speed.
public let hangGuard: Duration = .seconds(60)

extension Trait where Self == TimeLimitTrait {
    /// The whole-test limit for a test that waits on `hangGuard`: past it by a margin, so a
    /// hung wait fails as the wait it was, by its own name, before the test is cut off.
    public static var hangGuarded: Self { .timeLimit(.minutes(2)) }
}

/// A wait for `hangGuard` that ran out: the event the test was waiting on never came.
public struct Hung: Error, CustomStringConvertible {
    public let waitingFor: String
    public var description: String { "waited \(hangGuard) for \(waitingFor), which never came" }
}

/// A value one side changes and the other waits on, until the change it is waiting for has
/// been made.
///
/// [LAW:no-ambient-temporal-coupling] A test that has to know something happened on
/// another thread is told so by that thread, never by sleeping until it probably has: a
/// sleep is a bet on the machine's speed, and a latch is the event itself.
public final class Latch<Value: Sendable>: @unchecked Sendable {
    /// Guards `value`, and is what a waiter sleeps on.
    private let condition = NSCondition()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// Makes `change` to the value and wakes every waiter to look at it again.
    public func update(_ change: (inout Value) -> Void) {
        condition.lock(); defer { condition.unlock() }
        change(&value)
        condition.broadcast()
    }

    /// The value as it stands.
    public var current: Value {
        condition.lock(); defer { condition.unlock() }
        return value
    }

    /// Blocks until `find` finds something in the value, and hands back what it found:
    /// what the test asserts on is the value its wait ended on, not one read again after.
    /// Throws `Hung` once `hangGuard` has passed without it.
    public func wait<Found>(for what: String, until find: (Value) -> Found?) throws -> Found {
        let guardEnds = Date(timeIntervalSinceNow: hangGuard.seconds)
        condition.lock(); defer { condition.unlock() }
        while true {
            if let found = find(value) { return found }
            guard condition.wait(until: guardEnds) else {
                if let found = find(value) { return found }
                throw Hung(waitingFor: what)
            }
        }
    }

    /// Blocks until `holds` is true of the value.
    public func wait(for what: String, until holds: (Value) -> Bool) throws {
        _ = try wait(for: what) { holds($0) ? () : nil }
    }
}

extension Latch where Value == Int {
    /// One more of whatever is being counted.
    public func count() { update { $0 += 1 } }
}

/// A named pipe a child process says something through, for a test that has to know the
/// child is running before it acts: the child writes a line to `path` - its pid, say - and
/// `line()` reads it.
///
/// Both ends are opened here, read end first, so the test's open never blocks on the child
/// and a read never sees the end of the stream before the child has written: this side
/// holds a writer of its own. A handshake that cannot be made leaves no descriptor and no
/// pipe behind.
public final class Handshake: @unchecked Sendable {
    public let path: String
    private let reading: Int32
    private let keeping: Int32

    public struct Failed: Error, CustomStringConvertible {
        public let description: String
    }

    public init() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "handshake-\(UUID().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else { throw Failed(description: "mkfifo \(path): \(String(cString: strerror(errno)))") }
        reading = open(path, O_RDONLY | O_NONBLOCK)
        guard reading >= 0 else {
            let code = errno
            unlink(path)
            throw Failed(description: "open \(path) to read: \(String(cString: strerror(code)))")
        }
        keeping = open(path, O_WRONLY | O_NONBLOCK)
        guard keeping >= 0 else {
            let code = errno
            close(reading)
            unlink(path)
            throw Failed(description: "open \(path) to write: \(String(cString: strerror(code)))")
        }
    }

    deinit {
        close(reading)
        close(keeping)
        unlink(path)
    }

    /// The first line the child writes, without its newline. Throws `Hung` once
    /// `hangGuard` has passed without one.
    public func line() throws -> String {
        var said: [UInt8] = []
        let guardEnds = ContinuousClock.now + hangGuard
        while true {
            if let newline = said.firstIndex(of: UInt8(ascii: "\n")) { return String(decoding: said[..<newline], as: UTF8.self) }
            let left = max(.zero, ContinuousClock.now.duration(to: guardEnds))
            guard left > .zero else { throw Hung(waitingFor: "a line through \(path)") }
            var waiting = pollfd(fd: reading, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, left.wholeMilliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw Failed(description: "poll \(path): \(String(cString: strerror(errno)))") }
            guard ready > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = read(reading, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count >= 0 else { throw Failed(description: "read \(path): \(String(cString: strerror(errno)))") }
            said += buffer.prefix(count)
        }
    }
}
