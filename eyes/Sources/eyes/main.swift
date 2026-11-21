import ArgumentParser
import EyesVerbs
import Telemetry
import Version

/// The binary: the verbs under one root. Every verb lives in EyesVerbs, where its tests
/// and vhid's MCP server reach it, so this module holds nothing to import and its entry
/// point is top-level code - the one form every build system links a `main` for.
struct Eye: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eyes",
        abstract: "Say what is on screen and where, in the coordinates vhid clicks.",
        version: Version.current,
        subcommands: [Windows.self, Displays.self, Find.self, Read.self, Hit.self, GrantsVerb.self]
    )
}

// ArgumentParser's own entry point, with the events still on their way out waited on
// before the process exits, however the verb ended. [LAW:nothing-unseen]
let failure: (any Error)?
do {
    var command = try Eye.parseAsRoot()
    if var command = command as? any AsyncParsableCommand { try await command.run() } else { try command.run() }
    failure = nil
} catch {
    failure = error
}
await Telemetry.drained()
Eye.exit(withError: failure)
