import ArgumentParser
import Telemetry

/// Where a unit of work came into an executable - typed on a command line, or called as an
/// MCP tool - and the command tree it is dispatched under.
///
/// [LAW:single-enforcer] Both executables open every command and every call through here,
/// so what a dispatched unit says of itself - where it came in, and which words of an error
/// stay off its record - is decided once for `vhid`, `vhid mcp` and `eyes` alike.
public struct Entry {
    public enum Door: String, Sendable { case cli, mcp }

    public let door: Door
    public let root: any ParsableCommand.Type

    public static func cli(under root: any ParsableCommand.Type) -> Entry { Entry(door: .cli, root: root) }
    public static func mcp(under root: any ParsableCommand.Type) -> Entry { Entry(door: .mcp, root: root) }

    /// Runs `work` as one dispatched unit named `name`, its record carrying what the caller
    /// was told of an error, as `said` words it.
    public func unit<T>(_ name: String, trace: Telemetry.Trace = .joined, _ work: () async throws -> T) async throws -> T {
        try await Telemetry.unit(name, trace: trace, said: said) {
            Telemetry.note(.entry, .string(door.rawValue))
            return try await work()
        }
    }

    /// What the caller was told of `error`, in the words a record and a command line's last
    /// words carry. Refused arguments are said to be refused and never quoted, at either
    /// door, however they were refused - by a tool, or by ArgumentParser's own validation -
    /// since their words can be text meant for a password field, and outlive the terminal
    /// and the conversation. Otherwise a cancellation as a caller is told it, since
    /// ArgumentParser has no words for one; an MCP caller is told the error as it reports
    /// itself; and a command line, nothing for `--help` and `--version`, which end well,
    /// and ArgumentParser's words for the rest.
    public func said(_ error: any Error) -> String {
        if error is ArgumentRefused || root.exitCode(for: error) == .validationFailure { return Telemetry.refusedArguments }
        if error.isCancellation { return error.reported }
        switch door {
        case .mcp: return error.reported
        case .cli: return root.exitCode(for: error) == .success ? "" : root.message(for: error)
        }
    }

    /// How a command line's verb ended well.
    public enum Ran: Sendable {
        case ran
        /// The verb answered with a verdict, the exit status a script reads.
        case judged(Int32)
        /// ArgumentParser answered in the verb's place - `--help`, `--version` - with an error
        /// that prints the answer and exits 0.
        case answered(by: any Error)

        /// Ends the process as this run ended, once its records are drained.
        public func exit(under root: any ParsableCommand.Type) -> Never {
            switch self {
            case .ran, .judged(0): root.exit()
            case .judged(let status): root.exit(withError: ExitCode(status))
            case .answered(let answer): root.exit(withError: answer)
            }
        }
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
        } catch let verdict as Verdict {
            return .judged(verdict.status)
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
}

/// A verb's verdict, the exit status a script reads, thrown as ArgumentParser's own clean
/// exits are, once the verb has said everything. Not a failure: the verb did what it was
/// for, so its record says it ran. [LAW:types-are-the-program] Apart from `ExitCode`, which
/// ends a run that failed after saying why.
public struct Verdict: Error {
    public let status: Int32
    public init(_ status: Int32) { self.status = status }
}
