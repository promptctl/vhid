import Installations

/// The `--service <name>` that this daemon's launchd plist passes it.
///
/// [LAW:parse-dont-validate] The one place this daemon's argv becomes an installation.
/// What comes back is an installation or nothing; there is no third answer and no
/// default, because installations run side by side and a daemon that guessed which one it
/// served would listen on another copy's Mach service - taking the endpoint from the
/// daemon that belongs there, silently, which is the whole failure this design exists to
/// remove. [LAW:no-silent-failure]
///
/// **It takes the name rather than a word naming one of two.** A closed vocabulary here -
/// `release` or `development` - would be this daemon deciding which installations may
/// exist, and anything linking this package to run a daemon of its own would need a word
/// added. The plist that registers an installation already carries its service name in
/// `MachServices`; passing that same name is one fact said once rather than a word and a
/// name that can disagree. [LAW:one-source-of-truth]
///
/// **A value that is itself a flag is a missing value, not a name.** argv cannot tell
/// `--service --verbose` from a name spelled `--verbose`, and the closed vocabulary this
/// replaced could not be fooled by one - so opening the set reopened that shape and this
/// closes it again. Measured on this Mac before the guard existed: the daemon took
/// `--verbose` as its name and said so under subsystem `--verbose`, a log nobody will
/// ever read. The rule lives here rather than in `Installation` because a leading `-` is
/// argv's to judge and nothing else's - launchd registers such a label without complaint.
/// [LAW:no-silent-failure]
///
/// [LAW:effects-at-boundaries] Pure, taking the arguments rather than reading
/// `CommandLine` itself, so every shape of a malformed plist is a test and not a daemon
/// that has to be installed to find out.
/// **Exactly one `--service`, or none this daemon will answer to.** Taking the first of
/// two would have it listen under one name while launchd started it as the other - the
/// precise failure this whole design exists to remove, arrived at through an argv nobody
/// looked at twice; a generated plist that merged two templates is how it happens. The
/// rule is a count and not a comparison, so two flags naming the same service are refused
/// alongside two that disagree: a parser that resolved the agreeing case would be
/// deciding which of two claims to believe, which is not its to decide at all, and a
/// plist that says a thing twice was assembled by something that did not know it had.
/// [LAW:no-silent-failure]
func serviceArgument(_ arguments: [String]) -> Installation? {
    let flags = arguments.indices.filter { arguments[$0] == "--service" }
    guard flags.count == 1, let flag = flags.first else { return nil }
    let name = arguments.index(after: flag)
    guard name < arguments.endIndex, !arguments[name].hasPrefix("-") else { return nil }
    return Installation(service: arguments[name])
}
