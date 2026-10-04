import ArgumentParser
import Foundation
import Input
import Signals
import Version

/// The verbs, against a daemon that owns the two virtual devices.
///
/// **A driver, not a nanny.** It types what it is told to type and clicks where it is
/// told to click. Whether a dialog is covering an app and whether the caller meant to do
/// this are not its questions to ask, so no verb here raises an app or reads the screen
/// - and nothing it prints tells the caller what to do next. What it reports is what the
/// devices did. The one question it will ask for a caller is which app is in front, when
/// `type` or `press` is told the app its keys are for, and then only to refuse.
@main
struct Vhid: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vhid",
        abstract: "Type and click on a virtual keyboard and mouse that macOS sees as hardware.",
        discussion: """
            The reports go to a root daemon that owns the devices, reached over its Mach service. \
            The daemon admits a caller carrying the certificate the daemon itself carries, so this \
            binary has to be signed with it: build with `make`, which signs, rather than with \
            `swift build`, which ad hoc signs and leaves every call refused.

            When a verb fails, `vhid doctor` names what is not in place and the step left.

            Coordinates are \(Help.place).
            """,
        version: Version.current,
        subcommands: [
            TypeCommand.self, PressCommand.self, GestureCommand.self, ClickCommand.self, MoveCommand.self, ScrollCommand.self,
            DragCommand.self, CursorCommand.self, PlayCommand.self, RecordCommand.self, McpCommand.self, DriverCommand.self,
            ServiceCommand.self, DoctorCommand.self,
        ])

    /// ArgumentParser's own `main`, run as one invocation: parsing argv is part of it, so
    /// a refused argument leaves a record too. [LAW:nothing-unseen]
    ///
    /// Control-C and SIGTERM stop the invocation, not the process under it. The first
    /// cancels the verb, which unwinds as a withdrawn MCP call does, letting go of what it
    /// holds, and its record says it was cancelled and what it had sent; then the process
    /// dies by that signal, as it would have unwatched. A verb that does not hear the
    /// cancel - `record` answers the signal itself, `doctor` reads on to its end - ends and
    /// exits as it would have anyway. A second signal is someone the first did not reach,
    /// and ends the process at once, unrecorded.
    static func main() async {
        let invocation = Task {
            try await Invocation.record(_commandName, via: .commandLine, to: EventExport.configured().export) { try await run(nil, in: $0) }
        }
        let first = FirstSignal()
        let watch = SignalWatch { number in
            guard first.take(number) else { die(by: number) }
            invocation.cancel()
        }
        let ending = await invocation.result
        withExtendedLifetime(watch) {}
        switch (ending, first.taken) {
        case (.success, _): return
        case (.failure(let error), let number?) where error.isCancellation:
            // Said, because it can be the one report of what the verb had done when the
            // signal landed. [LAW:no-silent-failure]
            FileHandle.standardError.write(Data("vhid: \(error.reported)\n".utf8))
            die(by: number)
        case (.failure(let error), _): exit(withError: error)
        }
    }

    /// Parses `arguments` (argv when `nil`), names `invocation` after the command they
    /// chose, and runs it.
    static func run(_ arguments: [String]?, in invocation: Invocation) async throws {
        var command = try parseAsRoot(arguments)
        invocation.named(name(of: type(of: command)))
        if var command = command as? AsyncParsableCommand {
            try await command.run()
        } else {
            try command.run()
        }
    }

    /// A command's name as it is typed after `vhid`, `scroll` or `driver state`, which is
    /// also its MCP tool's name; `vhid` for the root.
    static func name(of command: any ParsableCommand.Type) -> String {
        func path(from node: any ParsableCommand.Type) -> [String]? {
            if ObjectIdentifier(node) == ObjectIdentifier(command) { return [] }
            return node.configuration.subcommands.lazy.compactMap { sub in path(from: sub).map { [sub._commandName] + $0 } }.first
        }
        // `parseAsRoot` hands back a command declared under this root, or ArgumentParser's
        // own `help`, which it puts in every root's tree without declaring it - for
        // `vhid help`, and for `--help` after any verb.
        return path(from: Self.self).map { $0.isEmpty ? _commandName : $0.joined(separator: " ") } ?? command._commandName
    }
}
