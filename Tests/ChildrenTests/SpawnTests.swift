import Children
import Darwin
import OwnThread
import Testing

/// What `spawn` promises of a child: what a SIGTERM does to it, and what of this process's
/// it holds. A suite of its own thread because each test waits for its child.
@Suite(.ownThread) struct SpawnTests {
    enum Ending: Equatable {
        case exited(Int32)
        case signalled(Int32)
    }

    /// How `script` ended under /bin/sh started by `spawn`.
    static func ending(of script: String) throws -> Ending {
        let pid = try spawn("/bin/sh", ["-c", script], stdio: [:])
        var status: Int32 = 0, collected: pid_t
        repeat { collected = waitpid(pid, &status, 0) } while collected == -1 && errno == EINTR
        try #require(collected == pid)
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signalled(signal)
    }

    /// vhidd ignores SIGTERM, and an ignored signal is inherited across exec: a child left
    /// with that would survive the SIGTERM sent to stop it.
    ///
    /// SIGTERM is ignored by the whole test process while the child is started, as it is by
    /// vhidd for good, and put back after: the disposition is the process's, and there is
    /// no other way to be the parent this is a promise about.
    @Test func aChildOfAProcessThatIgnoresSIGTERMIsEndedByOne() throws {
        let before = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, before) }
        #expect(try Self.ending(of: "kill -TERM $$; exit 0") == .signalled(SIGTERM))
    }

    /// A thread dispatch runs a queue on blocks SIGTERM, and vhidd starts children from
    /// such threads. A blocked signal is inherited as an ignored one is, and a SIGTERM
    /// sent to that child waits on a mask nothing lifts. Blocked here by hand, so the test
    /// says the same on whichever thread it is given.
    @Test func aChildStartedFromAThreadThatBlocksSIGTERMIsEndedByOne() throws {
        var term = sigset_t(), before = sigset_t()
        sigemptyset(&term)
        sigaddset(&term, SIGTERM)
        pthread_sigmask(SIG_BLOCK, &term, &before)
        defer { pthread_sigmask(SIG_SETMASK, &before, nil) }
        #expect(try Self.ending(of: "kill -TERM $$; exit 0") == .signalled(SIGTERM))
    }

    /// A descriptor of this process's that the child was not given is not the child's,
    /// though it was opened to be inherited: a pipe whose writing end this process has
    /// closed has ended, while a child that would have held that end is still running.
    /// Asked of the pipe and not of the child, because a shell has descriptors of its own
    /// and a number it finds open need not be one it was handed.
    @Test(.timeLimit(.minutes(1))) func aChildHoldsNoDescriptorItWasNotGiven() throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        defer { close(ends[0]) }
        #expect(fcntl(ends[1], F_GETFD) & FD_CLOEXEC == 0)
        let pid = try spawn("/bin/sleep", ["600"], stdio: [:])
        defer { kill(pid, SIGKILL); waitpid(pid, nil, 0) }
        close(ends[1])
        var byte: UInt8 = 0
        #expect(read(ends[0], &byte, 1) == 0)
    }

    @Test func aChildThatCannotBeStartedIsSaidByNameWithWhy() {
        let refused = #expect(throws: CouldNotStart.self) { try spawn("/nonexistent/tool", [], stdio: [:]) }
        #expect(refused?.description == "could not start /nonexistent/tool: No such file or directory (2)")
    }
}
