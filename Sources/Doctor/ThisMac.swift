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
    static func read(for installation: Installation) -> Readiness {
        Readiness(
            installation: installation,
            driver: Result { DriverState(try DriverProbe.facts()) },
            job: Result { try LaunchdProbe.standing(of: installation) },
            daemon: DaemonProbe.reading(of: installation),
            keyboardSetupAssistantAnswered: Result { try KeyboardTypeCache.read().answersThisKeyboard })
    }
}
