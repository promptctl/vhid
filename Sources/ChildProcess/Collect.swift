import Darwin

/// How a child ended: what it exited with, or the signal that ended it.
public enum Ending: Equatable, Sendable {
    case exited(Int32)
    case signalled(Int32)
}

/// A child that could not be collected, and the errno `waitpid` gave for it.
public struct Uncollected: Error, Equatable {
    public let code: Int32
}

/// Waits for the child `pid` to end and collects it, after which the pid is nobody's.
/// [LAW:one-source-of-truth] The one reading of a wait status.
public func collect(_ pid: pid_t) throws(Uncollected) -> Ending {
    var status: Int32 = 0, collected: pid_t
    repeat { collected = waitpid(pid, &status, 0) } while collected == -1 && errno == EINTR
    // [LAW:no-silent-failure] A child something else collected has no status to give, and
    // the zero `status` began at would say it had succeeded.
    guard collected == pid else { throw Uncollected(code: errno) }
    let signal = status & 0x7f
    return signal == 0 ? .exited((status >> 8) & 0xff) : .signalled(signal)
}
