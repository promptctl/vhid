import ArgumentParser
import Foundation
import Input
import os
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
    /// holds, and its record says which signal landed and what the verb had sent; then the
    /// process dies by that signal, as it would have unwatched - which a shell reads as
    /// Control-C, and stops a loop for - however the verb ended, even well. Only a verb
    /// that answers the signal itself, as `record` does by finishing, exits as it would
    /// have anyway. A second signal is someone the first did not reach, and ends the
    /// process at once, unrecorded.
    ///
    /// [LAW:single-enforcer] The one watch on these signals in a command-line run: a verb
    /// that answers them, as `record` does, hears the cancel, and reads which signal it
    /// was from the invocation.
    static func main() async {
        let first = FirstSignal()
        let running = OSAllocatedUnfairLock<Task<Void, any Error>?>(initialState: nil)
        // Watched before the verb starts, so that no signal finds it under the default
        // disposition; one that lands before the verb exists cancels it as it is made.
        // The cancel is handed to a thread of its own: a verb's cancel handler runs where
        // the cancel is made, and one that blocked here would hold up the second signal.
        let watch = SignalWatch { number in
            guard first.take(number) else { die(by: number) }
            let task = running.withLock { $0 }
            DispatchQueue.global().async { task?.cancel() }
        }
        let invocation = Task {
            try await Invocation.record(_commandName, via: .commandLine, stoppedBy: first, to: EventExport.configured().export) {
                try await run(nil, in: $0)
            }
        }
        running.withLock { running in
            running = invocation
            if first.taken != nil { invocation.cancel() }
        }
        let ending = await invocation.result
        withExtendedLifetime(watch) {}
        switch (ending, first.unanswered) {
        case (.success, nil): return
        case (.success, let number?): die(by: number)
        case (.failure(let error), nil) where !error.isCancellation: exit(withError: error)
        case (.failure(let error), let number):
            // Said, because it can be the one report of what the verb had done when the
            // signal landed, in the words its record has. [LAW:no-silent-failure]
            let words = said(for: error)
            if !words.isEmpty { FileHandle.standardError.write(Data("vhid: \(words)\n".utf8)) }
            guard let number else { exit(withError: exitCode(for: error)) }
            die(by: number)
        }
    }

    /// What the command line says of a verb that ended in `error`, which is what its
    /// record carries; nothing for a verb that said everything itself on its way out, as
    /// `doctor` does, or for `--help` and `--version`, which end well. A cancellation is
    /// said in the words an MCP caller is given, since ArgumentParser has none of its own
    /// for it. [LAW:one-source-of-truth]
    static func said(for error: any Error) -> String {
        if error.isCancellation { return error.reported }
        return exitCode(for: error) == .success ? "" : message(for: error)
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
