import ChildProcess
import Darwin
import OwnThread
import Testing

/// What `spawn` promises of a child: what a signal does to it, and what of this process's
/// it holds. A suite of its own thread because each test waits for its child.
@Suite(.ownThread) struct SpawnTests {
    /// How `script` ended under /bin/sh started by `spawn`.
    static func ending(of script: String) throws -> Ending {
        try collect(spawn("/bin/sh", ["-c", script], stdio: [:]))
    }

    /// vhidd ignores SIGTERM, and an ignored signal is inherited across exec: a child left
    /// with that would survive the SIGTERM sent to stop it. The promise is of every signal,
    /// so it is asked of one more that nothing names: SIGUSR1, which this process has no
    /// use for, where an ignored SIGINT would take ^C from whoever is running the tests.
    ///
    /// The signal is ignored by the whole test process while the child is started, as
    /// SIGTERM is by vhidd for good, and put back after: the disposition is the process's,
    /// and there is no other way to be the parent this is a promise about.
    @Test(arguments: [SIGTERM, SIGUSR1]) func aChildOfAProcessThatIgnoresASignalIsEndedByIt(number: Int32) throws {
        let before = signal(number, SIG_IGN)
        defer { signal(number, before) }
        #expect(try Self.ending(of: "kill -\(number) $$; exit 0") == .signalled(number))
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
    /// and a number it finds open need not be one it was handed. Asked with a limit: a
    /// read would wait on a child that held the end for as long as the child ran.
    @Test func aChildHoldsNoDescriptorItWasNotGiven() throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        defer { close(ends[0]) }
        #expect(fcntl(ends[1], F_GETFD) & FD_CLOEXEC == 0)
        let pid = try spawn("/bin/sleep", ["600"], stdio: [:])
        defer { kill(pid, SIGKILL); _ = try? collect(pid) }
        close(ends[1])
        var ended = pollfd(fd: ends[0], events: Int16(POLLIN), revents: 0)
        #expect(poll(&ended, 1, 5000) == 1)
        #expect(ended.revents & Int16(POLLHUP) != 0)
    }

    @Test func aChildThatCannotBeStartedIsSaidByNameWithWhy() {
        let refused = #expect(throws: CouldNotStart.self) { try spawn("/nonexistent/tool", [], stdio: [:]) }
        #expect(refused?.description == "could not start /nonexistent/tool: No such file or directory (2)")
    }
}
