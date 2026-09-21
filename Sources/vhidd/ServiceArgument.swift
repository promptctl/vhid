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
/// [LAW:effects-at-boundaries] Pure, taking the arguments rather than reading
/// `CommandLine` itself, so every shape of a malformed plist is a test and not a daemon
/// that has to be installed to find out.
func serviceArgument(_ arguments: [String]) -> Installation? {
    guard let flag = arguments.firstIndex(of: "--service") else { return nil }
    let name = arguments.index(after: flag)
    guard name < arguments.endIndex else { return nil }
    return Installation(service: arguments[name])
}
