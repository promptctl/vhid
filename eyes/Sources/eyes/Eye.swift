import ArgumentParser
import EyesVerbs
import Telemetry
import Version

/// The binary.
///
/// Not named `main.swift`: a file by that name is the module's top-level entry point, and
/// a module with one cannot be imported, which would leave everything below it reachable
/// only by running the binary and reading its output. [LAW:verifiable-goals]
@main
struct Eye: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eyes",
        abstract: "Say what is on screen and where, in the coordinates vhid clicks.",
        version: Version.current,
        subcommands: [Windows.self, Displays.self, Find.self, Read.self, Hit.self, GrantsVerb.self]
    )

    /// ArgumentParser's own entry point, run as one unit of work named for the verb it
    /// parses to, and with every record still on its way out waited on before the process
    /// exits, however the verb ended. Parsing is part of the unit, so refused arguments
    /// leave a record too. [LAW:nothing-unseen]
    static func main() async {
        let failure: (any Error)?
        do {
            failure = try await Telemetry.unit(_commandName, said: said) {
                Telemetry.note("entry", "cli")
                do {
                    var command = try parseAsRoot()
                    Telemetry.name(type(of: command)._commandName)
                    if var command = command as? any AsyncParsableCommand { try await command.run() } else { try command.run() }
                    return nil
                } catch where exitCode(for: error) == .success {
                    // `--help` and `--version` arrive as errors that exit 0: the unit did
                    // what it was asked.
                    return error
                }
            }
        } catch {
            failure = error
        }
        await Telemetry.drained()
        exit(withError: failure)
    }

    /// What the record says of a verb that ended in `error`: what the operator was told,
    /// except refused arguments' words.
    static func said(for error: any Error) -> String? {
        exitCode(for: error) == .validationFailure ? Telemetry.refusedArguments : message(for: error)
    }
}
