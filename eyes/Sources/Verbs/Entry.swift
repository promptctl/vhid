import ArgumentParser
import Telemetry

/// Where a unit of work came into an executable: typed on a command line, or called as an
/// MCP tool.
///
/// [LAW:single-enforcer] Both executables open every command and every call through here,
/// so what a dispatched unit says of itself - where it came in, and which words of an error
/// stay off its record - is decided once for `vhid`, `vhid mcp` and `eyes` alike.
public enum Entry: String, Sendable {
    case cli, mcp

    /// Runs `work` as one dispatched unit named `name`. `said` gives what the caller was told
    /// of an error, which the record carries - except refused arguments' words, which can
    /// quote text meant for a password field, and outlive the terminal and the conversation.
    public func unit<T>(_ name: String, trace: Telemetry.Trace = .joined, said: (any Error) -> String?,
                        _ work: () async throws -> T) async throws -> T {
        try await Telemetry.unit(name, trace: trace, said: { ArgumentRefused.refuses($0) ? Telemetry.refusedArguments : said($0) }) {
            Telemetry.note(.entry, .string(rawValue))
            return try await work()
        }
    }

    /// How a command line's verb ended well.
    public enum Ran: Sendable {
        case ran
        /// ArgumentParser answered in the verb's place - `--help`, `--version` - with an error
        /// that prints the answer and exits 0.
        case answered(by: any Error)
    }

    /// Parses `arguments` (argv when `nil`) under `root`, names the unit underway after the
    /// command they chose, and runs it.
    public static func commandLine<Root: ParsableCommand>(_ root: Root.Type, _ arguments: [String]?) async throws -> Ran {
        do {
            var command = try root.parseAsRoot(arguments)
            Telemetry.name(name(of: type(of: command), under: root))
            if var command = command as? any AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
            return .ran
        } catch where root.exitCode(for: error) == .success {
            return .answered(by: error)
        }
    }

    /// A command's name as it is typed after the executable's, `scroll` or `driver state`,
    /// which is also its MCP tool's name; the root's own for the root.
    public static func name(of command: any ParsableCommand.Type, under root: any ParsableCommand.Type) -> String {
        func path(from node: any ParsableCommand.Type) -> [String]? {
            if ObjectIdentifier(node) == ObjectIdentifier(command) { return [] }
            return node.configuration.subcommands.lazy.compactMap { sub in path(from: sub).map { [sub._commandName] + $0 } }.first
        }
        // `parseAsRoot` hands back a command declared under this root, or ArgumentParser's
        // own `help`, which it puts in every root's tree without declaring it - for
        // `vhid help`, and for `--help` after any verb.
        return path(from: root).map { $0.isEmpty ? root._commandName : $0.joined(separator: " ") } ?? command._commandName
    }
}

/// Arguments an MCP tool refused, in the words the model reads.
public struct ArgumentRefused: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }

    /// Whether `error` is a refusal of the arguments a unit was given: a tool's, or a command
    /// line's, which ArgumentParser exits with its validation status.
    static func refuses(_ error: any Error) -> Bool {
        // Any command answers `exitCode(for:)`, which reads only the error.
        error is ArgumentRefused || ReadGrants.exitCode(for: error) == .validationFailure
    }
}
