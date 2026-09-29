import ArgumentParser
import Installations

/// Which installation's daemon a command talks to.
///
/// [LAW:one-source-of-truth] Declared once and taken by every verb through
/// `@OptionGroup`, so the flag is spelled, defaulted and described the same way
/// everywhere rather than four times with three agreements.
///
/// **A service name and not a word from a list.** The set of installations is open -
/// anything linking `Installations` may run a daemon under a name this package has never
/// heard of - so a flag offering `release` or `development` would be a second, closed
/// idea of what installations exist, and a name outside it would be unreachable from
/// here. What the flag takes is the name itself, which reaches every daemon there is or
/// will be.
struct ServiceOption: ParsableArguments {
    @Option(
        name: .customLong("service"),
        help: ArgumentHelp(
            "The Mach service of the vhidd to talk to.",
            discussion: "Defaults to \(ServiceOption.byDefault), the installation this vhid was built for. "
                + "vhid's installed copy is \(Installation.release); "
                + "the copy built from a working tree is \(Installation.development)."))
    var stated: String?

    /// The installation a verb acts on when none is stated: the one this binary was built
    /// for. [LAW:one-source-of-truth]
    static let byDefault = Installation.thisBuild

    /// [LAW:parse-dont-validate] The one place the flag becomes an installation. Every
    /// verb holds the value and never the string, so nothing downstream re-examines a
    /// name that has already been read.
    func installation() throws -> Installation {
        guard let stated else { return Self.byDefault }
        guard let installation = Installation(service: stated) else {
            throw ValidationError(
                "--service \(stated.debugDescription) is not a Mach service name: it must not be empty "
                + "or hold whitespace, because launchd registers no label with a space in it.")
        }
        return installation
    }

    /// The name is read at validation and again when a verb wants the value.
    ///
    /// ArgumentParser calls this before any `run`, which is what makes a refused name
    /// come back as that verb's own usage rather than the root command's - and before the
    /// keyboard layout is read or a connection is made. Reading it twice costs a struct;
    /// the rule it is read by still lives in exactly one place, `Installation.init`.
    /// [LAW:single-enforcer]
    func validate() throws {
        _ = try installation()
    }

    init() {}
}
