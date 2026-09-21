/// One installation of the vhid daemon, as the names macOS keys it by.
///
/// [LAW:one-type-per-behavior] An installation is not a kind of program. It is this
/// program installed somewhere, and what separates two of them is configuration - one
/// string, from which every other name is built. So this is one type whose instances are
/// installations, and no caller ever branches on which one it holds: it asks the value for
/// the name it needs. [LAW:dataflow-not-control-flow]
///
/// **It used to be a closed enum of two, and that is what changed.** vhid installs twice -
/// the copy that runs all day and the copy being worked on - but a package whose set of
/// installations is compiled in cannot be consumed by anything that needs a third. A
/// project that links this to run a daemon of its own registers it under its own name,
/// with no edit here and no case added: the name arrives as data, which is what makes the
/// set open. The two below are vhid's own, named so that the installer, the scripts and
/// the tests read one source rather than three. [LAW:one-source-of-truth]
///
/// [LAW:one-way-deps] This module depends on nothing, which is what lets the root daemon -
/// which must stay lean - and every client read from one source without either depending
/// on the other.
public struct Installation: Sendable, Hashable, CustomStringConvertible {
    /// The Mach service this installation's daemon listens on and its clients dial.
    ///
    /// Exactly one process may own a Mach service name, which is what makes two
    /// installations under two names able to run at once - and two installations under one
    /// name a silent failure, where one holds the endpoint and the other is simply never
    /// given it.
    public let service: String

    /// The launchd job that owns this installation's service.
    ///
    /// **Derived from the service and never stored beside it, because the two being equal
    /// is load-bearing.** An installation's daemon can be registered two ways - an
    /// `SMAppService` job from inside a bundle, or a plist in /Library/LaunchDaemons that a
    /// script bootstraps - and exactly one of them may hold it at a time. One label across
    /// both paths is what makes a second claimant fail loudly instead of quietly. Measured
    /// on this Mac:
    ///
    /// - two jobs under one label: the second `launchctl bootstrap` exits 5, "Bootstrap
    ///   failed: Input/output error", and no job is added;
    /// - two labels naming one Mach service: the second bootstrap exits 0, the job runs,
    ///   and it is never given the endpoint - it has no `endpoints` entry at all.
    ///
    /// The second is what low-keyboard-3ti.13 recorded in the field: a helper sitting
    /// unreachable for twelve minutes while logging that it was listening. Two stored
    /// fields could drift back into exactly that; one field cannot.
    /// [LAW:one-source-of-truth] [LAW:no-silent-failure]
    public var launchdLabel: String { service }

    /// What a log line and a refusal call this installation, which is its service name -
    /// the only name it has.
    public var description: String { service }

    /// [LAW:parse-dont-validate] The one place a string becomes an installation. What comes
    /// back is an installation or nothing, and the output type is the proof the check ran,
    /// so nothing downstream re-examines the name it was handed.
    ///
    /// Refuses the empty string and anything holding whitespace, because those are the two
    /// that cannot survive the trip this name takes: it is passed through argv, written as
    /// a launchd `Label`, and registered as a Mach service, and launchd accepts no label
    /// with a space in it. Nothing stricter is checked here - a reverse-DNS shape, a length
    /// cap - because launchd owns those rules and a second copy of them in this module is a
    /// copy that can disagree with the system actually doing the registering.
    /// [LAW:one-source-of-truth]
    public init?(service: String) {
        guard !service.isEmpty, !service.contains(where: \.isWhitespace) else { return nil }
        self.service = service
    }
}

public extension Installation {
    /// The reverse-DNS namespace every name vhid registers is built from. Named once, so a
    /// rename reaches all of them together. [LAW:one-source-of-truth]
    private static let namespace = "ai.promptctl.vhid"

    /// The daemon nested under the namespace it belongs to, the shape Apple's own embedded
    /// helpers take, so the parentage Background Task Management records reads in the name.
    private static let daemon = namespace + ".vhidd"

    /// What a development installation suffixes onto the release one's name, so the two are
    /// told apart the same way wherever they are told apart.
    private static let developmentSuffix = ".dev"

    /// vhid's installed copy: registered by the installer, left running.
    ///
    /// Force-unwrapped, and that is the right answer rather than a shortcut: this string is
    /// a literal in this file, so a nil here is this file contradicting itself at load and
    /// there is no caller who could do anything about it. A test below reads both of these
    /// back, so the unwrap is proven rather than hoped.
    static let release = Installation(service: daemon)!

    /// vhid's copy built from the working tree, run beside the installed one.
    static let development = Installation(service: daemon + developmentSuffix)!

    /// The two vhid installs itself, for an installer, a script or a test that needs both.
    ///
    /// Not every installation there is - the set is open, and anything linking this package
    /// may register its own - so nothing may read this as "all of them". It is vhid's own
    /// two, which is a different and smaller claim.
    static let vhids: [Installation] = [.release, .development]

    /// Where a daemon that could not name itself says so.
    ///
    /// Every other subsystem a daemon logs under is its own installation's service name,
    /// which is precisely what a daemon started without one does not have. The old shape
    /// answered this by logging the failure under every installation there was, so a
    /// reader would find it whichever they looked at; an open set has no "every" to
    /// enumerate, and one fixed place to look is what replaces it. It is the namespace
    /// rather than any installation's service, so this message never lands in a running
    /// installation's log claiming to be from it. [LAW:no-silent-failure]
    static let unnamedSubsystem = namespace

    /// The domain every refusal from a daemon crosses under.
    ///
    /// The one name here that does not vary by installation, because an error's domain says
    /// what kind of thing refused and every daemon built from this package refuses for
    /// identical reasons under identical rules. A client matching on it is matching on the
    /// kind, not on which copy answered - including a client of an installation this package
    /// has never heard of.
    static let refusalDomain = daemon + ".refusal"
}
