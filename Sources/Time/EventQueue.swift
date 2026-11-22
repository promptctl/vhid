import Foundation

/// A kqueue whose every wait is one blocking wait toward a deadline, ended by what it
/// watches, by a trigger of the waiter's own, or by a move of the timeline.
///
/// [LAW:one-type-per-behavior] Every thread in vhid that waits on descriptors - a command's
/// streams and exit, the daemon link's socket - waits this one way, so a test that moves
/// its clock wakes each of them, and none waits out a real span of its own.
public final class EventQueue: Sendable {
    private let descriptor: Int32

    /// The user event a move of the timeline triggers, which a wait takes as a reason to
    /// look at its deadline again and never hands back as an event.
    private static let timelineMoved: UInt = .max

    public init() throws(Failed) {
        descriptor = kqueue()
        guard descriptor >= 0 else { throw Failed(call: "kqueue", code: errno) }
        do { try watch(Self.timelineMoved, EVFILT_USER, EV_ADD | EV_CLEAR) } catch { close(descriptor); throw error }
    }

    deinit { close(descriptor) }

    /// Adds, changes or removes one watch, throwing the code the kernel refused it with.
    public func watch(_ ident: UInt, _ filter: Int32, _ flags: Int32, _ fflags: UInt32 = 0) throws(Failed) {
        var change = kevent(ident: ident, filter: Int16(filter), flags: UInt16(flags | EV_RECEIPT), fflags: fflags, data: 0, udata: nil)
        var receipt = kevent()
        let refused = kevent(descriptor, &change, 1, &receipt, 1, nil) == 1 ? Int32(receipt.data) : errno
        guard refused == 0 else { throw Failed(call: "kevent", code: refused) }
    }

    /// Triggers the user event `ident`, watched with `EVFILT_USER`, from any thread.
    public func trigger(_ ident: UInt) {
        var trigger = kevent(ident: ident, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil)
        _ = kevent(descriptor, &trigger, 1, nil, 0, nil)
    }

    /// At most `count` of the events that come by `deadline`. Empty once it has passed and a
    /// last look finds nothing, so what came exactly at the deadline is still heard.
    public func events(by deadline: Deadline, atMost count: Int) throws(Failed) -> [kevent] {
        var events = Array(repeating: kevent(), count: count + 1)
        while true {
            let passed = deadline.passed
            var ready: Int32 = 0
            var failure: Int32 = 0
            func look(_ span: Duration) {
                var patience = span.timespec
                ready = kevent(descriptor, nil, 0, &events, Int32(events.count), &patience)
                failure = errno
            }
            if passed {
                look(.zero)
            } else {
                deadline.block(waking: { [self] in trigger(Self.timelineMoved) }) { span in
                    look(span)
                    return ready != 0
                }
            }
            if ready < 0, failure == EINTR { continue }
            guard ready >= 0 else { throw Failed(call: "kevent", code: failure) }
            let heard = events.prefix(Int(ready)).filter { !($0.filter == Int16(EVFILT_USER) && $0.ident == Self.timelineMoved) }
            if !heard.isEmpty || passed { return Array(heard) }
        }
    }

    /// A call on the queue the kernel refused, with its code.
    public struct Failed: Error, Equatable {
        public let call: String
        public let code: Int32
    }
}
