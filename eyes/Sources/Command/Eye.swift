import ArgumentParser
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
        subcommands: [Windows.self, Displays.self, Find.self, Read.self, GrantsVerb.self, Mcp.self]
    )

    /// ArgumentParser's own entry point, with the events still on their way out waited on
    /// before the process exits, however the verb ended. [LAW:nothing-unseen]
    static func main() async {
        let failure: (any Error)?
        do {
            var command = try parseAsRoot()
            if var command = command as? any AsyncParsableCommand { try await command.run() } else { try command.run() }
            failure = nil
        } catch {
            failure = error
        }
        await Telemetry.drained()
        exit(withError: failure)
    }
}
