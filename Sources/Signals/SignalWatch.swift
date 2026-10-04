import Foundation
import Synchronization

/// Signals the process is told to ignore, so that it can answer them rather than obey
/// them. Their default disposition ends the process where it stands - mid-burst, with a
/// key still down - and what a run needs instead is the chance to unwind through its own
/// ending.
///
/// [LAW:one-source-of-truth] The one place the `signal(2)`-then-`DispatchSource`
/// sequence lives: every process here that answers a signal rather than obeying it
/// watches through this. What differs between one watcher and the next is the answer and
/// the queue it runs on, and both are values this takes; a second copy of the mechanism
/// would be a second place to fix a missed signal or a wrong queue.
/// [LAW:one-type-per-behavior]
///
/// Held for as long as the answers are wanted: the sources stop when the watch is
/// released while the signals stay ignored, so a watch nobody holds is a process nothing
/// short of `SIGKILL` can stop.
public struct SignalWatch {
    private let sources: [any DispatchSourceSignal]

    /// `answer` is handed the number on `queue`. The source coalesces, so one call can
    /// stand for any number of deliveries of that signal, and an answer must be idempotent.
    public init(
        on numbers: [Int32] = [SIGINT, SIGTERM],
        answeringOn queue: DispatchQueue = .global(),
        answer: @escaping @Sendable (Int32) -> Void
    ) {
        sources = numbers.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { answer(number) }
            return source
        }
        sources.forEach { $0.resume() }
    }
}

/// The first signal a watch answered, kept so that a later one can be told from it: the
/// first asks a run to wind down, and one after it is someone the first did not reach.
/// Answered from whichever thread the watch runs its answer on.
public final class FirstSignal: Sendable {
    private let kept = Mutex<Int32?>(nil)

    public init() {}

    /// Whether `number` is the first signal taken, which is kept; any after it is not.
    public func take(_ number: Int32) -> Bool {
        kept.withLock { kept in
            defer { kept = kept ?? number }
            return kept == nil
        }
    }

    /// The first signal taken, if one has been.
    public var taken: Int32? { kept.withLock { $0 } }
}

/// Ends the process by `number` under its default disposition, as if the signal had never
/// been watched, so the parent sees the process killed by it - which a shell reads as
/// Control-C, and stops a loop for - rather than an exit status that only resembles it.
public func die(by number: Int32) -> Never {
    signal(number, SIG_DFL)
    kill(getpid(), number)
    // The default disposition of a watched signal ends the process; this is never reached.
    exit(128 + number)
}
