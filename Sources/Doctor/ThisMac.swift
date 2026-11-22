import Time
import ChildProcess
import DriverExtension
import Installations

public extension Readiness {
    /// Where this Mac stands for `installation`, read now.
    ///
    /// [LAW:effects-at-boundaries] The one place every reading is taken, so `vhid doctor`
    /// and its MCP tool read the same things the same way and differ only in where the
    /// list is printed. Each probe that fails arrives as its failure and becomes its row's
    /// `unreadable`. The status call claims nothing and the rest only read, with one reach
    /// beyond reading that no Mach client can avoid: a daemon launchd holds a job for but
    /// has not started is started by the call, as it would be by any verb. [LAW:one-source-of-truth]
    ///
    /// In this order, and in series, because of that start: the daemon files the Keyboard
    /// Setup Assistant answer before it listens, so a cache read after its reply sees what
    /// a daemon started by the call filed. [LAW:no-ambient-temporal-coupling]
    ///
    /// Every reading by the one `deadline` made where doctor was asked, so doctor answers
    /// within the limit its caller gave: a row read after the limit has passed says it was
    /// not read, and why. All of them by `stop`, which ends whichever is reading.
    static func read(for installation: Installation, by deadline: Deadline, or stop: Command.Stop) -> Readiness {
        Readiness(
            installation: installation,
            driver: Result { DriverState(try DriverProbe.facts(by: deadline, or: stop)) },
            job: Result { try LaunchdProbe.standing(of: installation, by: deadline, or: stop) },
            daemon: DaemonProbe.reading(of: installation, by: deadline),
            keyboardSetupAssistantAnswered: Result { try KeyboardTypeCache.read().answersThisKeyboard })
    }
}
