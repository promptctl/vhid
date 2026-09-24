/// The readings `vhid doctor` takes of this Mac, as values.
///
/// [LAW:effects-at-boundaries] Nothing in this file reads anything. These are the shapes a
/// reading arrives in, so the table that turns them into requirements is a pure function
/// of them, and every combination - including the ones a given Mac cannot be put into -
/// is a value a test can construct. The probes that produce them live at the edge.

/// Where launchd stands on the job that holds this installation's Mach service.
///
/// Three answers and no more, because vhid registers its daemon one way: a plist in
/// /Library/LaunchDaemons, bootstrapped under a label equal to the service
/// (`Installation.launchdLabel`). low-talker had a fourth, a bootstrapped job shadowing an
/// app's own `SMAppService` registration, which vhid has no app to make.
public enum JobStanding: Sendable, Hashable, CaseIterable {
    /// A job is loaded under this installation's label and launchd gave it the endpoint.
    case holdingTheService
    /// A job is loaded under this installation's label and launchd holds no endpoint for
    /// the service on its behalf.
    ///
    /// Named for what was read and not for a cause, because launchd's record has two
    /// causes and prints them identically - measured, no `endpoints` block at all either
    /// way. The usual one is another job holding the service: launchd does not make the
    /// loser loud, and a second claimant on a Mach service name bootstraps with exit 0,
    /// runs, and never gets the endpoint (recorded on `Installation.launchdLabel`). The
    /// other is a plist under this label that never named the service. A job in this
    /// state looks loaded and answers nothing, which is why it is a standing of its own.
    case loadedWithoutTheService
    /// launchd has no job under this installation's label.
    case noJob
}

/// What one side-effect-free status call to the daemon came back as.
///
/// One round trip, classified, because the four ways it goes are four different steps for
/// a person and one raw `NSError` names none of them apart: a service nobody holds, a
/// daemon that holds it and will not answer, a daemon that answers and refuses this
/// binary's signature, and a daemon that answers.
public enum DaemonReading: Sendable, Hashable {
    /// The daemon answered, and said which process holds the devices, if any.
    ///
    /// An answer is also the proof that both devices are up: the daemon begins listening
    /// only once it has reached pqrs's daemon and both devices are ready, and it exits
    /// when that connection is lost. A daemon without its devices has no listener to
    /// answer from.
    case answered(holder: Int32?)
    /// The daemon refused this process: it admits only callers signed with its own
    /// certificate (NSCocoaErrorDomain 4097 at the client).
    case refusedThisSignature
    /// Nothing holds the service, so there was nobody to ask (NSCocoaErrorDomain 4099).
    case unreachable(reason: String)
    /// Something holds the service and said nothing before the deadline.
    ///
    /// launchd holds a job's endpoint from load, whether or not the daemon has started
    /// listening on it, so a daemon that cannot bring its devices up - it exits, and
    /// launchd starts it again - is reached and never answers.
    case silent(reason: String)
    /// The call failed in a way none of the above names. Kept whole rather than folded
    /// into the nearest of them: a reading this build cannot classify is shown as what it
    /// said. [LAW:no-silent-failure]
    case failed(reason: String)

    /// Whether a daemon is known to have started, and so to have had its chance to file
    /// Keyboard Setup Assistant's answer - which it does first, before it reaches the
    /// devices or listens on anything.
    ///
    /// A refusal counts: the listener that refused this signature runs after the filing.
    /// Silence does not, although a daemon that exits and is started again may well have
    /// filed each time: what was read is that nobody answered, not that anybody ran, and
    /// the row that asks this sends a person to a log only when there is a start whose
    /// filing that log would hold. [LAW:no-silent-failure] Exhaustive with no `default`, so
    /// a reading added later has to answer this rather than inheriting a fallback.
    /// [LAW:types-are-the-program]
    public var daemonHasStarted: Bool {
        switch self {
        case .answered, .refusedThisSignature: true
        case .unreachable, .silent, .failed: false
        }
    }

    /// Whether something holds the service - answering, refusing, or holding it silent.
    ///
    /// Asked of a label launchd has no job under, where a yes means a job under some other
    /// label holds this service. A failure this build cannot classify answers no: nothing
    /// it said is known to come from a holder, and a no leaves the launchd row saying only
    /// what launchd itself said. [LAW:no-silent-failure]
    public var someoneHoldsTheService: Bool {
        switch self {
        case .answered, .refusedThisSignature, .silent: true
        case .unreachable, .failed: false
        }
    }
}
