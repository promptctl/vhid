import DriverExtension
import Installations

public extension Readiness {
    /// Where this Mac stands for `installation`, read now.
    ///
    /// [LAW:effects-at-boundaries] The one place every reading is taken, so `vhid doctor`
    /// and its MCP tool read the same things the same way and differ only in where the
    /// list is printed. Each probe that fails arrives as its failure and becomes its row's
    /// `unreadable`; none of them changes anything on the Mac - the status call claims
    /// nothing, and the rest only read. [LAW:one-source-of-truth]
    static func read(for installation: Installation) -> Readiness {
        Readiness(
            installation: installation,
            driver: Result { DriverState(try DriverProbe.facts()) },
            job: Result { try LaunchdProbe.standing(of: installation) },
            daemon: DaemonProbe.reading(of: installation),
            keyboardSetupAssistantAnswered: Result { try KeyboardTypeCache.read().answersThisKeyboard })
    }
}
