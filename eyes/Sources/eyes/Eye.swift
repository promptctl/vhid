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
        subcommands: [Windows.self, Displays.self, Find.self, Read.self, Hit.self, GrantsVerb.self, ReadGrants.self]
    )

    /// ArgumentParser's own entry point, run as one unit of work named for the verb it
    /// parses to, and with every record still on its way out waited on before the process
    /// exits, however the verb ended. Parsing is part of the unit, so refused arguments
    /// leave a record too. [LAW:nothing-unseen]
    static func main() async {
        let ending: Result<Entry.Ran, any Error>
        do {
            ending = .success(try await Entry.cli.unit(_commandName, said: { Entry.said(for: $0, under: Self.self) }) {
                try await Entry.commandLine(Self.self, nil)
            })
        } catch {
            ending = .failure(error)
        }
        await Telemetry.drained()
        switch ending {
        case .success(let ran): ran.exit(under: Self.self)
        case .failure(let error): exit(withError: error)
        }
    }
}
