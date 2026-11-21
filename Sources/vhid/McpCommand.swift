import ArgumentParser
import Darwin
import Foundation
import Input
import Installations
import MCP
import Turns
import Signals
import System
import Telemetry
import Version

/// The verbs as MCP tools, over stdio, for an agent that drives a Mac in one session
/// rather than a process per keystroke.
struct McpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the verbs as MCP tools over stdin and stdout.",
        discussion: """
            Newline-delimited JSON-RPC on stdin and stdout, and nothing else on stdout: every \
            diagnostic goes to stderr. The tools are \(Tools.all.map(\.tool.name).joined(separator: ", ")). \
            They take what the verbs of the same name take and answer with what those verbs \
            print.

            Calls that reach the daemon run one at a time, even when a client sends them \
            together; look asks nothing of it, so a look waiting on a change holds up no act. \
            Calls sent together run in no promised order: a call that must follow another, a \
            type after the click that focuses a field, is sent once the first one's answer is \
            back. Each call connects to the daemon and disconnects when it returns. The daemon \
            serves one client at a time, so a session that held its connection open would \
            refuse every other caller for as long as it ran: a vhid click from a shell, and \
            every other agent's session. Between calls, this session holds nothing.
            """)

    @OptionGroup var service: ServiceOption

    /// What the server is and how to work with it, as it says at initialize: the one
    /// screen-point space and the look-act-look loop. The plugin's skill opens with the
    /// same text, held to this by a test. [LAW:one-source-of-truth]
    static let guidance = """
        vhid reads the screen and drives a virtual keyboard and mouse that macOS takes for hardware, from one MCP server. `look` reads: the displays and windows, the app in front or one named, and where text is in it. `click`, `type`, `press`, `scroll`, `drag`, `move` and `gesture` act.

        Every point `look` prints is the point the acting tools take, as printed: no scaling, no offset, negative on a display left of or above the main one. Beside each point, `look` prints a box around the text that holds the point, as x,y,width,height in the same points: the form its `rect` takes, and `click`, `move` and `scroll` take it too, as `box`, and `drag` as `from` or `to`, pressing a point drawn inside it as a hand lands somewhere on a button rather than on its exact centre.

        Nothing here decides anything. `click` presses whatever is at the point it is given, `type` types into whatever has keyboard focus, and `look` reports what is on screen, not whether an act did what was meant. So work in a loop:

        1. Look: `look` alone for the displays, the windows and the app in front; with `text` for where that text is.
        2. Act on what you saw.
        3. Look again at the same place. `look` with `text`, `until` and a `timeout` waits for the change; do not sleep and retry.

        Done means a look after the act showed the change. An act's answer says the act happened, not what it did.
        """

    /// What a client's initialize tells it: the guidance, then which server and version it
    /// is talking to. The model reads a server's instructions, not its `serverInfo`, so the
    /// version is said here too, from the one the binary was stamped with, and an agent
    /// can tell which of the guidance's arguments it can pass. [LAW:one-source-of-truth]
    static let instructions = guidance + "\n\nThis is vhid \(Version.current)."

    /// The server as a client's initialize finds it, with `tools` attached to run against
    /// `installation`, each call held `underway` on the transport it will be started on,
    /// carried by `flights` until it is done, and recorded as one invocation handed to `hand`.
    static func server(_ tools: [VerbTool] = Tools.all, on installation: Installation, over transport: AnsweringTransport,
                       recordingTo hand: @escaping Invocation.Hand, stoppedBy signals: FirstSignal? = nil, carriedBy flights: Flights) async -> Server {
        let server = Server(name: "vhid", version: Version.current, instructions: instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        // Calls to the daemon, one at a time. The SDK runs every request in a task of its own,
        // so two calls sent together - a click and a type in one turn of an agent's - would
        // reach for the daemon at once, and it serves one client: the second came back refused
        // as busy, by this very process. Taking turns makes the session one client again, and
        // no two calls interleave report by report. Calls sent together run in no promised
        // order: JSON-RPC promises none among requests in flight together.
        let turns = Turns()
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools.map(\.tool)) }
        await server.withMethodHandler(CallTool.self) { request in try await flights.carry {
            // Recorded under the method, not the name: a name the client made up is not a
            // verb, and would make one event per made-up name. The error says which.
            guard let verb = tools.first(where: { $0.tool.name == request.name }) else {
                let refusal = MCPError.invalidParams("there is no tool called \(request.name.debugDescription)")
                return try await Invocation.record(CallTool.name, via: .mcp, stoppedBy: signals, to: hand) { _ in throw refusal }
            }
            // A verb that could not do what it was asked is a tool error, whose words the
            // model reads; a protocol error is for a request that named no tool at all. A
            // call the client withdrew is answered like any other, and the transport drops
            // the answer, as the MCP spec says a cancelled request's is. What the verb said on
            // the way out still goes to stderr, because it can be the one report of what the
            // verb had already done when it was withdrawn. [LAW:no-silent-failure]
            return try await transport.underway {
                do {
                    let said = try await Invocation.record(request.name, via: .mcp, stoppedBy: signals, to: hand) { _ in
                        try await verb.call(request.arguments ?? [:], on: installation, taking: turns)
                    }
                    return .init(content: [.text(text: said, annotations: nil, _meta: nil)], isError: false)
                } catch where Task.isCancelled {
                    FileHandle.standardError.write(Data("vhid: \(request.name) withdrawn: \(error.reported)\n".utf8))
                    return .init(content: [.text(text: "withdrawn: \(error.reported)", annotations: nil, _meta: nil)], isError: true)
                } catch {
                    return .init(content: [.text(text: error.reported, annotations: nil, _meta: nil)], isError: true)
                }
            }
        } }
        return server
    }

    func run() async throws {
        let installation = try service.installation()
        // [LAW:single-enforcer] Stdout belongs to the protocol, and that is made true of the
        // descriptor rather than asked of every line of code that might print. The
        // transport writes to a copy of the real stdout, and descriptor 1 becomes stderr, so
        // a stray `print` anywhere in the process lands among the diagnostics and not in
        // the middle of a JSON-RPC message.
        let protocolOut = FileDescriptor(rawValue: dup(STDOUT_FILENO))
        guard protocolOut.rawValue >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            throw Errno(rawValue: errno)
        }

        try await Self.serve(on: installation, over: AnsweringTransport(StdioTransport(output: protocolOut)), recordingTo: { Telemetry.send($0.record) },
                             stoppedBy: Invocation.current?.signals)
    }

    /// Serves `tools` over `transport` until the client hangs up or the serving task is
    /// cancelled, as Control-C and SIGTERM cancel it. A cancel withdraws every call owed,
    /// so each one stops as a client's cancel would stop it, and ends the session. Returns
    /// once every call has ended, throwing if it was cancelled. The records are the
    /// outbox's, which the process drains before it exits.
    /// Each call's record names the signal in `signals` that stopped the session, if one did.
    ///
    /// The cancel has to be carried in by hand: the SDK serves from a task of its own,
    /// which no cancel of this one reaches.
    static func serve(_ tools: [VerbTool] = Tools.all, on installation: Installation, over transport: AnsweringTransport,
                      recordingTo hand: @escaping Invocation.Hand, stoppedBy signals: FirstSignal? = nil) async throws {
        let flights = Flights()
        let server = await server(tools, on: installation, over: transport, recordingTo: hand, stoppedBy: signals, carriedBy: flights)
        try await server.start(transport: transport)
        await withTaskCancellationHandler {
            await server.waitUntilCompleted()
        } onCancel: {
            Task {
                await transport.withdrawEverything()
                await server.stop()
            }
        }
        await flights.landed()
        try Task.checkCancellation()
    }
}

/// What the server has under way and must see done before the process exits: tool calls
/// still running when the client hung up.
///
/// [LAW:nothing-unseen] Without it, a client that closed stdin mid-`type` would end the
/// process under the keystrokes still going out, and they would leave no record.
actor Flights {
    private var underway = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `body`, counted as under way until it returns.
    nonisolated func carry<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await depart()
        do {
            let done = try await body()
            await arrive()
            return done
        } catch {
            await arrive()
            throw error
        }
    }

    /// Returns once nothing is under way.
    func landed() async {
        guard underway > 0 else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func depart() { underway += 1 }

    private func arrive() {
        underway -= 1
        guard underway == 0 else { return }
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
